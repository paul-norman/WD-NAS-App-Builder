#!/bin/sh
# kvweb from its package (tests/common/nas.sh), with the Valkey app (tests/kvweb/with): waiting for Valkey (as at boot,
# when the NAS starts kvweb first), its own user, only on the NAS itself, Valkey's password in its environment and never
# on its command line, keys seen through it, read only, Valkey's password changed on Valkey's page (kvweb follows), new
# passwords for its site, removal
. /t/common/nas.sh kvweb
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers then
# run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
U=http://127.0.0.1:8082
health() { curl -s -m 5 $U/api/health; }
vcli() { REDISCLI_AUTH="$(awk '$1 == "requirepass" { print $2 }' $P/_valkey/valkey.conf)" $P/valkey/binaries/valkey-cli -h 127.0.0.1 "$@" 2>/dev/null; }

echo "== without Valkey"
install_app
grep -q "The Valkey app isn't installed" /tmp/debug_apkg && [ ! -f /var/run/kvweb.pid ] && pass "not started without the Valkey app (and says so)" || fail "no valkey: $(tail -n 3 /tmp/debug_apkg)"

echo "== waiting for Valkey (as at boot: kvweb starts first)"
install_app valkey; sh $P/valkey/stop.sh $P/valkey > /dev/null 2>&1; sleep 1
sh $P/kvweb/start.sh $P/kvweb > /tmp/start.log 2>&1
grep -q "waiting for Valkey to answer" /tmp/debug_apkg && ! listening 8082 && pass "started while Valkey was down: it returned at once, waiting in the background" || fail "wait: $(tail -n 3 /tmp/debug_apkg)"
sh $P/valkey/start.sh $P/valkey > /dev/null 2>&1
wait_port 8082 30 && health | grep -q '"database":true' && pass "up once Valkey answered, connected: $(health)" || { fail "not up after Valkey: $(tail -n 5 /tmp/debug_apkg; cat $D/kvweb.log)"; exit 1; }
page_up kvweb
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"0.2.5"' ] && [ "$(echo "$ST" | j '$d["connected"]')" = true ] && [ "$(echo "$ST" | j '$d["valkey"]')" = true ] \
	&& pass "the page: kvweb 0.2.5, connected to Valkey" || fail "status: $(echo "$ST" | head -c 300)"

echo "== its user, where it listens, Valkey's password"
PID=$(cat /var/run/kvweb.pid); VPW=$(awk '$1 == "requirepass" { print $2 }' $P/_valkey/valkey.conf)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 87 ] && [ "$(stat -c '%U %G %a' $D/htpasswd)" = "root share 640" ] && [ "$(stat -c '%a' $D)" = 751 ] \
	&& pass "runs as its own user (87); its htpasswd file Nginx's group's only" || fail "users: $(stat -c '%n %U %G %a' $D $D/htpasswd)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1F92") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv "^0100007F:" \
	&& fail "listens beyond the NAS" || pass "listens only on the NAS itself (127.0.0.1)"
! tr '\0' ' ' < /proc/$PID/cmdline | grep -q -- "$VPW" && health | grep -q '"database":true' \
	&& pass "Valkey's password given in its environment (connected), not on its command line" || fail "password on its command line: $(tr '\0' ' ' < /proc/$PID/cmdline)"

echo "== keys, read only"
vcli SET suite:greeting hello > /dev/null
curl -s -m 5 "$U/api/keys" | grep -q '"suite:greeting"' && pass "a key set in Valkey seen through kvweb" || fail "keys: $(curl -s -m 5 "$U/api/keys" | head -c 200)"
R=$(post readonly -d readonly=1); sleep 1; PID=$(cat /var/run/kvweb.pid)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && tr '\0' ' ' < /proc/$PID/cmdline | grep -q -- "-readonly" && health | grep -q '"database":true' \
	&& pass "read only: restarted with -readonly, still connected" || fail "readonly: $R $(tr '\0' ' ' < /proc/$PID/cmdline)"
post readonly -d readonly= > /dev/null; sleep 1

echo "== Valkey's password changed on Valkey's page"
OLD=$(cat /var/run/kvweb.pid)
page_up valkey; R=$(post set_password -d password=); page_up kvweb; sleep 2
NEWPID=$(cat /var/run/kvweb.pid 2>/dev/null)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -n "$NEWPID" ] && [ "$NEWPID" != "$OLD" ] && health | grep -q '"database":true' \
	&& curl -s -m 5 "$U/api/keys" | grep -q '"suite:greeting"' && pass "kvweb restarted with Valkey's new password, still connected" || fail "valkey password: $R $(health)"

echo "== its site's password"
R=$(post set_password -d password=short); echo "$R" | grep -q "12-128" && pass "a short password refused" || fail "short: $R"
NEW=$(post set_password -d password=Suite-pass-1234 | j '$d["password"]' | tr -d '"')
H=$(cut -d: -f2- $D/htpasswd)
[ "$NEW" = Suite-pass-1234 ] && [ "$(php -r 'echo crypt($argv[1], $argv[2]) === $argv[2] ? "ok" : "no";' Suite-pass-1234 "$H")" = ok ] && grep -q '^admin:\$6\$' $D/htpasswd \
	&& pass "a password of my own: in the htpasswd file as a SHA-512 crypt hash for admin" || fail "set password: $NEW $(cat $D/htpasswd)"

echo "== removal"
finish_app
