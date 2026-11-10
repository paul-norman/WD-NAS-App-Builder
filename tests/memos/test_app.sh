#!/bin/sh
# The Memos app from its package (tests/common/nas.sh), with the Nginx app (tests/memos/with): its first start as its
# own user, only on the NAS itself, its admin declared in Memos' configuration (nobody else can claim it or sign up),
# a note made and read, its site through Nginx with its address in Memos, the page (status, the password and a new
# one, a password changed in Memos kept across restarts), sign-ups handed back to Memos' own settings, backups with
# the note in them, on the network too and back, removal keeping its data
. /t/common/nas.sh memos
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
M=http://127.0.0.1:5230
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "memos.$DOMAIN:443:127.0.0.1" "$@" "https://memos.$DOMAIN$p"; }
# Signs in to Memos: signin <user> <password> [base] - prints the access token (empty if refused)
signin() { curl -sk -m 10 --resolve "memos.$DOMAIN:443:127.0.0.1" -X POST -H 'Content-Type: application/json' -d "{\"passwordCredentials\":{\"username\":\"$1\",\"password\":\"$2\"}}" "${3:-$M}/api/auth/signin" | j '$d["accessToken"] ?? ""' | tr -d '"'; }
# Signs up (unauthenticated): signup <user> - prints the HTTP status
signup() { code -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"Some-pass-123\"}" "$M/api/users"; }
# Whether it listens beyond the NAS itself (port 5230 = 146E)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":146E") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }
# Restarts it, as at boot
restart() { sh $P/memos/memos_ctl.sh restart > /tmp/restart.log 2>&1; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
curl -s $M/api/instance/profile | grep -q '"version":"' \
    && pass 'answering on 5230' || { fail "not answering: $(tail -n 10 $D/memos.log; grep memos /tmp/debug_apkg | tail -n 15)"; exit 1; }
PID=$(cat /var/run/memos.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 61 ] && [ "$(stat -c '%U %a' $D/data)" = 'memos 700' ] \
    && [ "$(stat -c '%U %G %a' $D/admin_password)" = 'root memos 640' ] && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] \
    && [ -f $D/data/memos_prod.db ] && pass 'runs as its own user (61), its data its own, the password root'"'"'s (its group reads it)' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/data)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'only on the NAS itself (127.0.0.1:5230) - with the Nginx app installed' \
    || fail "listens beyond the NAS: $(cat $D/settings)"
grep -q 'memos-daily' /var/spool/cron/crontabs/root && grep -q 'memos-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"

echo '== its admin, no one else'
PW=$(cat $D/admin_password)
TOKEN=$(signin admin "$PW")
[ -n "$TOKEN" ] && [ -z "$(signin admin wrong-password)" ] && [ "$(curl -s $M/api/instance/profile | j '$d["needsSetup"]')" = false ] \
    && pass 'its admin signs in with the page'"'"'s password (a wrong one refused), no first-account setup offered' || fail "admin: $(cat $D/config/app.json)"
[ "$(signup mallory)" = 403 ] && pass 'nobody can sign themselves up' || fail "sign-up: $(signup mallory2)"
R=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"content":"Hello from the NAS #test","visibility":"PRIVATE"}' $M/api/memos)
curl -s -H "Authorization: Bearer $TOKEN" $M/api/memos | grep -q 'Hello from the NAS #test' && ! curl -s $M/api/memos | grep -q 'Hello from the NAS' \
    && pass 'a note made and read (not shown without signing in)' \
    || fail "note: listed: $(curl -s -H "Authorization: Bearer $TOKEN" $M/api/memos | head -c 300) - anonymous: $(curl -s -w ' %{http_code}' $M/api/memos | head -c 300)"

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:5230' $P/_nginx/sites/60-app-memos.conf 2>/dev/null && site / | grep -qi '<html' \
    && [ -n "$(signin admin "$PW" "https://memos.$DOMAIN")" ] && pass "its site https://memos.$DOMAIN/ (signing in through it)" \
    || fail "site: $(ls $P/_nginx/sites; site / | head -c 300)"
[ "$(curl -s $M/api/instance/profile | j '$d["instanceUrl"]')" = "\"https://memos.$DOMAIN\"" ] && pass 'its address in Memos: the site'"'"'s' \
    || fail "instance URL: $(curl -s $M/api/instance/profile)"

echo '== its page'
page_up memos
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"26.11.0"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://memos.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["restart_needed"]')" = false ] \
    && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] && pass 'status: running, Memos 26.11.0, its site, its password' \
    || fail "status: $(echo "$ST" | head -c 400)"
R=$(post new_password -d confirm=1); NEW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && [ -n "$(signin admin "$NEW")" ] && [ -z "$(signin admin "$PW")" ] \
    && pass 'a new password from the page (the old one refused)' || fail "new password: $R"
TOKEN=$(signin admin "$NEW")
code -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"users/admin","password":"Mine-in-Memos-1"}' "$M/api/users/admin?updateMask=password" > /dev/null
restart
[ -n "$(signin admin Mine-in-Memos-1)" ] && [ -z "$(signin admin "$NEW")" ] && pass 'a password changed in Memos kept across a restart' \
    || fail "own password: $(tail -n 5 $D/memos.log)"

echo '== sign-ups are Memos'"'"' own setting'
TOKEN=$(signin admin Mine-in-Memos-1)
R=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"instance/settings/GENERAL","generalSetting":{"disallowUserRegistration":false}}' $M/api/instance/settings/GENERAL)
[ "$R" = 200 ] && [ "$(signup alice)" = 200 ] && restart && [ "$(signup bob)" = 200 ] \
    && pass 'turned on in Memos'"'"' settings, and kept across a restart' || fail "sign-ups: $R $(cat $D/config/app.json)"

echo '== backups'
R=$(post backup -d confirm=1)
F=$(ls $D/backups/memos-*.tar.gz 2>/dev/null | head -n 1)
mkdir -p /tmp/restore && tar -xzf "$F" -C /tmp/restore 2>/dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%a' "$F")" = 600 ] \
    && $P/memos/binaries/sqlite3 /tmp/restore/memos_prod.db "SELECT content FROM memo" | grep -q 'Hello from the NAS #test' \
    && pass 'a backup from the page, root'"'"'s only, with the note in it' || fail "backup: $R $(ls -la $D/backups)"
post settings -d listen=local -d backup_keep=2 > /dev/null
for i in 1 2 3; do sleep 1; sh $P/memos/memos_ctl.sh backup > /dev/null 2>&1; done
[ "$(ls $D/backups/memos-*.tar.gz | wc -l)" = 2 ] && pass 'only the newest 2 kept' || fail "kept: $(ls $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:5230)' || fail "listen all: $R"
post settings -d listen=local -d backup_keep=14 > /dev/null
! listens_beyond && [ -n "$(signin admin Mine-in-Memos-1)" ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'memos-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-memos.conf ] && [ -f $D/data/memos_prod.db ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
