#!/bin/sh
# The template app from its package (tests/common/nas.sh), with the Nginx app (tests/template/with): its first start as
# its own user, only on the NAS itself, its example page through its site, its management page, on the network too and
# back, its cron lines, removal. A new app's suite starts from this one
. /t/common/nas.sh template
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
M=http://127.0.0.1:8090
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "template.$DOMAIN:443:127.0.0.1" "$@" "https://template.$DOMAIN$p"; }
# Whether it listens beyond the NAS itself (port 8090 = 1F9A)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F9A") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 8090 30 && curl -s $M/ | grep -q 'The template app works' && pass 'answering on 8090, with its example page' \
    || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
PID=$(cat /var/run/template.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 62 ] && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] \
    && pass 'runs as its own user (62), its settings root'"'"'s' || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'only on the NAS itself (127.0.0.1:8090) - with the Nginx app installed' \
    || fail "listens beyond the NAS: $(cat $D/settings)"
grep -q 'template-daily' /var/spool/cron/crontabs/root && grep -q 'template-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily job and weekly update check in root'"'"'s crontab' || fail "cron: $(cat /var/spool/cron/crontabs/root)"

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:8090' $P/_nginx/sites/60-app-template.conf 2>/dev/null && site / | grep -q 'The template app works' \
    && pass "its site https://template.$DOMAIN/ (its example page)" || fail "site: $(ls $P/_nginx/sites; site / | head -c 300)"

echo '== its page'
page_up template
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"0.35.0"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://template.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["listen"]')" = '"local"' ] \
    && pass 'status: running, miniserve 0.35.0, its site, only through Nginx' || fail "status: $(echo "$ST" | head -c 400)"
OLD=$PID; R=$(post restart -d confirm=1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cat /var/run/template.pid)" != "$OLD" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' $M/)" = 200 ] \
    && pass 'restarted from the page' || fail "restart: $R"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q '^LISTEN=all$' $D/settings && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:8090)' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && [ "$(curl -s -o /dev/null -w '%{http_code}' $M/)" = 200 ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'template-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-template.conf ] && [ -f $D/www/index.html ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
