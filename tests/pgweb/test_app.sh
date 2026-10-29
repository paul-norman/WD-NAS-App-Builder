#!/bin/sh
# pgweb from its package (tests/common/nas.sh), with the PostgreSQL and Nginx apps (tests/pgweb/with): its first start as
# its own user, only on the NAS itself, its site through Nginx asking for the page's password first, a PostgreSQL login
# on pgweb's own form and a query, read only, new passwords, removal
. /t/common/nas.sh pgweb
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers then
# run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "pgweb.$DOMAIN:443:127.0.0.1" "$@" "https://pgweb.$DOMAIN$p"; }

echo "== with PostgreSQL and Nginx"
install_app postgresql
wait_port 5432 60 && pass "PostgreSQL answering" || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
page_up postgresql; PGPW=$(post password | j '$d["password"]' | tr -d '"')
install_app nginx
wait_port 443 30 && pass "Nginx answering" || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo "== first start"
install_app
wait_port 8081 30 && pass "answering on 8081" || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
page_up pgweb
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"0.17.0"' ] && [ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://pgweb.$DOMAIN/\"" ] \
	&& pass "the page: pgweb 0.17.0 answering, its address https://pgweb.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 300)"
PID=$(cat /var/run/pgweb.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 86 ] && [ "$(stat -c '%U %G %a' $D/htpasswd)" = "root share 640" ] \
	&& [ "$(stat -c '%u %a' $D/password)" = "0 600" ] && [ "$(stat -c '%a' $D)" = 751 ] \
	&& pass "runs as its own user (86); its htpasswd file Nginx's group's only, its password root's" || fail "users: $(stat -c '%n %U %G %a' $D $D/htpasswd $D/password)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1F91") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv "^0100007F:" \
	&& fail "listens beyond the NAS" || pass "listens only on the NAS itself (127.0.0.1)"
tr '\0' ' ' < /proc/$PID/cmdline | grep -q -- "--sessions --no-ssh" && ! tr '\0' ' ' < /proc/$PID/cmdline | grep -q -- "--auth" \
	&& pass "each visitor's own PostgreSQL login, no SSH tunnels, no password on its command line" || fail "cmdline: $(tr '\0' ' ' < /proc/$PID/cmdline)"

echo "== its site, through Nginx"
PW=$(post password | j '$d["password"]' | tr -d '"')
grep -q "auth_basic_user_file $D/htpasswd" $P/_nginx/sites/60-app-pgweb.conf && [ "$(site /api/info -o /dev/null -w '%{http_code}')" = 401 ] \
	&& [ "$(site /api/info -u admin:wrong -o /dev/null -w '%{http_code}')" = 401 ] && site /api/info -u "admin:$PW" | grep -q '"version":"0.17.0"' \
	&& pass "its site asks for the page's password: none or a wrong one refused (401), the right one reaches pgweb" \
	|| fail "site: $(site /api/info -u "admin:$PW" | head -c 200) $(grep auth $P/_nginx/sites/60-app-pgweb.conf)"

echo "== a PostgreSQL login and a query"
S=suite-session-1
R=$(site /api/connect -u "admin:$PW" -H "x-session-id: $S" --data-urlencode "url=postgres://postgres:$PGPW@127.0.0.1:5432/postgres?sslmode=disable")
Q=$(site '/api/query' -u "admin:$PW" -H "x-session-id: $S" --data-urlencode 'query=SELECT 6 * 7 AS answer')
echo "$Q" | grep -q '"rows":\[\[42\]\]' && pass "logged in to PostgreSQL on its form, a query: $(echo "$Q" | head -c 120)" || fail "query: $R / $Q"
R=$(site /api/connect -u "admin:$PW" -H "x-session-id: other" --data-urlencode "url=postgres://postgres:wrong@127.0.0.1:5432/postgres?sslmode=disable")
echo "$R" | grep -qi "authentication failed" && pass "a wrong PostgreSQL password refused: $(echo "$R" | head -c 100)" || fail "wrong pg password: $R"

echo "== read only"
R=$(post readonly -d readonly=1); sleep 1
site /api/connect -u "admin:$PW" -H "x-session-id: $S" --data-urlencode "url=postgres://postgres:$PGPW@127.0.0.1:5432/postgres?sslmode=disable" > /dev/null
Q=$(site '/api/query' -u "admin:$PW" -H "x-session-id: $S" --data-urlencode 'query=CREATE TABLE suite_t (i int)')
[ "$(echo "$R" | j '$d["ok"]')" = true ] && echo "$Q" | grep -qi "read-only" && [ "$(get status | j '$d["readonly"]')" = true ] \
	&& pass "read only: a change refused ($(echo "$Q" | head -c 100))" || fail "readonly: $R / $Q"
post readonly -d readonly= > /dev/null; sleep 1
site /api/connect -u "admin:$PW" -H "x-session-id: $S" --data-urlencode "url=postgres://postgres:$PGPW@127.0.0.1:5432/postgres?sslmode=disable" > /dev/null
site '/api/query' -u "admin:$PW" -H "x-session-id: $S" --data-urlencode 'query=CREATE TABLE suite_t (i int)' | grep -qi "error" \
	&& fail "still read only" || pass "read only off: changes allowed again"

echo "== new passwords"
R=$(post set_password -d password=short); echo "$R" | grep -q "12-128" && pass "a short password refused" || fail "short: $R"
NEW=$(post set_password -d password= | j '$d["password"]' | tr -d '"')
[ ${#NEW} = 20 ] && [ "$(site /api/info -u "admin:$PW" -o /dev/null -w '%{http_code}')" = 401 ] && [ "$(site /api/info -u "admin:$NEW" -o /dev/null -w '%{http_code}')" = 200 ] \
	&& [ "$(post password | j '$d["password"]' | tr -d '"')" = "$NEW" ] && pass "a generated password: the old one refused at once, the new one in (nothing restarted)" || fail "new password: $NEW"

echo "== on the network too (its own login)"
direct() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" http://127.0.0.1:8081/api/info; }
# Whether it listens on every address: 0.0.0.0, or :: (as Go does - IPv4 too)
everywhere() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F91") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -q "^00000000:\|^00000000000000000000000000000000:"; }
[ "$(grep '^LISTEN=' $D/settings)" = LISTEN=local ] && pass "only through the Nginx app by default (the Nginx app is installed)" || fail "default: $(cat $D/settings)"
R=$(post listen -d listen=all); sleep 1; PID=$(cat /var/run/pgweb.pid)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && everywhere \
	&& [ "$(direct)" = 401 ] && [ "$(direct -u admin:wrong)" = 401 ] && [ "$(direct -u "admin:$NEW")" = 200 ] && [ "$(get status | j '$d["answering"]')" = true ] \
	&& pass "on the network: pgweb's own login (none or a wrong one refused, the page's password in), its page still sees it answering" \
	|| fail "network: none $(direct) wrong $(direct -u admin:wrong) right $(direct -u "admin:$NEW") answering $(get status | j '$d["answering"]') everywhere: $(everywhere && echo yes || echo no)"
[ "$(site /api/info -u "admin:$NEW" -o /dev/null -w '%{http_code}')" = 200 ] && pass "through Nginx too, with the same user name and password (one login for both)" || fail "nginx + pgweb login"
NEW2=$(post set_password -d password= | j '$d["password"]' | tr -d '"'); sleep 1
[ "$(direct -u "admin:$NEW")" = 401 ] && [ "$(direct -u "admin:$NEW2")" = 200 ] && [ "$(site /api/info -u "admin:$NEW2" -o /dev/null -w '%{http_code}')" = 200 ] \
	&& pass "a new password: pgweb restarted with it (the old one refused, on the network and through Nginx)" || fail "new password on the network: $(direct -u "admin:$NEW2")"
post listen -d listen=local > /dev/null; sleep 1
! everywhere && [ "$(direct)" = 200 ] \
	&& pass "only through the Nginx app again: on 127.0.0.1, without its own login" || fail "back to local"

echo "== without the extra password (only PostgreSQL's own login)"
# Waits (up to 5 seconds) for Nginx's reload to apply: until its site answers with the status given
reloaded() { i=0; while [ $i -lt 10 ]; do [ "$(site /api/info -o /dev/null -w '%{http_code}')" = "$1" ] && return 0; sleep 0.5; i=$((i + 1)); done; return 1; }
R=$(post auth -d auth=); reloaded 200
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! grep -q auth_file $P/pgweb/nginx.json && ! grep -q auth_basic $P/_nginx/sites/60-app-pgweb.conf \
	&& [ "$(site /api/info -o /dev/null -w '%{http_code}')" = 200 ] && [ "$(get status | j '$d["auth"]')" = false ] \
	&& pass "switched off: its nginx.json without the password file, its site answers without it" \
	|| fail "auth off: json auth_file $(grep -c auth_file $P/pgweb/nginx.json), site auth_basic $(grep -c auth_basic $P/_nginx/sites/60-app-pgweb.conf), code $(site /api/info -o /dev/null -w '%{http_code}'), status auth $(get status | j '$d["auth"]')"
post listen -d listen=all > /dev/null; sleep 1; PID=$(cat /var/run/pgweb.pid)
[ "$(direct)" = 200 ] && ! tr '\0' ' ' < /proc/$PID/cmdline | grep -q -- "--auth" && pass "on the network too: no login of its own (nor its password on its command line)" || fail "auth off on the network: $(direct)"
post listen -d listen=local > /dev/null; R=$(post auth -d auth=1); reloaded 401
grep -q '"auth_file": "_pgweb/htpasswd"' $P/pgweb/nginx.json && [ "$(site /api/info -o /dev/null -w '%{http_code}')" = 401 ] \
	&& [ "$(site /api/info -u "admin:$NEW2" -o /dev/null -w '%{http_code}')" = 200 ] && pass "switched on again: the password asked for first" || fail "auth on: $R"

echo "== removal"
finish_app
[ ! -f $P/_nginx/sites/60-app-pgweb.conf ] && pass "its site gone from Nginx" || fail "site left: $(ls $P/_nginx/sites)"
