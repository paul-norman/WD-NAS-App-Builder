#!/bin/sh
# The Homebox app from its package (tests/common/nas.sh), with the Nginx app (tests/homebox/with): its first start as
# its own user, only on the NAS itself, its admin account made by the app (nobody else can claim it or sign up), an
# item with an attachment (Homebox's temporary files on the data's disk), its site through Nginx with its address in
# Homebox's links, the page (status, the password and a new one, a reset link), invitations while sign-ups are off,
# sign-ups on and off, backups with the item and attachment in them, on the network too and back, removal keeping its
# data
. /t/common/nas.sh homebox
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
H=http://127.0.0.1:7745
A=$H/api/v1
ADMIN=admin@homebox.local
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "homebox.$DOMAIN:443:127.0.0.1" "$@" "https://homebox.$DOMAIN$p"; }
# Logs in: login <email> <password> [base] - prints the token (empty if refused)
login() { curl -sk -m 10 --resolve "homebox.$DOMAIN:443:127.0.0.1" -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"$2\"}" "${3:-$A}/users/login" | j '$d["token"] ?? ""' | tr -d '"'; }
# Signs up (unauthenticated): signup <email> [invitation token] - prints the HTTP status
signup() { code -H 'Content-Type: application/json' -d "{\"name\":\"Someone\",\"email\":\"$1\",\"password\":\"Some-pass-123\",\"token\":\"${2:-}\"}" "$A/users/register"; }
# Whether it listens beyond the NAS itself (port 7745 = 1E41)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1E41") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }
# Restarts it, as at boot
restart() { sh $P/homebox/homebox_ctl.sh restart > /tmp/restart.log 2>&1; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
curl -s $A/status | grep -q '"health":true' \
    && pass 'answering on 7745' || { fail "not answering: $(tail -n 10 $D/homebox.log; grep homebox /tmp/debug_apkg | tail -n 15)"; exit 1; }
PID=$(cat /var/run/homebox.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 58 ] && [ "$(stat -c '%U %a' $D/data)" = 'homebox 700' ] \
    && [ "$(stat -c '%U %a' $D/admin_password)" = 'root 600' ] && [ "$(stat -c '%U %a' $D/api_key_pepper)" = 'root 600' ] \
    && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] && [ -f $D/data/homebox.db ] \
    && pass 'runs as its own user (58), its data its own; its password, secret and settings root'"'"'s' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/data)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'only on the NAS itself (127.0.0.1:7745) - with the Nginx app installed' \
    || fail "listens beyond the NAS: $(cat $D/settings)"
grep -q 'homebox-daily' /var/spool/cron/crontabs/root && grep -q 'homebox-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ "$(curl -s $A/status | j '$d["allowRegistration"]')" = false ] && [ -f $D/admin_created ] \
    && pass 'sign-ups off once its admin account was made' || fail "status: $(curl -s $A/status)"

echo '== its admin, no one else'
PW=$(cat $D/admin_password)
TOKEN=$(login $ADMIN "$PW")
[ -n "$TOKEN" ] && [ -z "$(login $ADMIN wrong-password)" ] \
    && pass 'its admin logs in with the page'"'"'s password (a wrong one refused)' || fail "admin: $(grep homebox /tmp/debug_apkg | tail -n 5)"
[ "$(signup mallory@example.test)" = 403 ] && pass 'nobody can sign themselves up' || fail "sign-up: $(signup mallory2@example.test)"
ITEM=$(curl -s -H "Authorization: $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Cordless drill"}' $A/entities | j '$d["id"] ?? ""' | tr -d '"')
printf 'Receipt for the drill\n' > /tmp/receipt.txt
R=$(code -H "Authorization: $TOKEN" -F file=@/tmp/receipt.txt -F type=receipt -F name=receipt.txt $A/entities/$ITEM/attachments)
[ -n "$ITEM" ] && [ "$R" = 201 ] && curl -s -H "Authorization: $TOKEN" "$A/entities?q=drill" | grep -q 'Cordless drill' \
    && [ -n "$(find $D/data -type f -name '*.attrs')" ] \
    && pass 'an item with an attachment (stored in its data folder, by way of its own temporary folder)' \
    || fail "item: $ITEM attachment $R $(tail -n 3 $D/homebox.log)"
[ "$(code "$A/entities?q=drill")" = 401 ] && pass 'items not shown without logging in' || fail 'anonymous items'

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:7745' $P/_nginx/sites/60-app-homebox.conf 2>/dev/null && site / | grep -qi '<html' \
    && [ -n "$(login $ADMIN "$PW" "https://homebox.$DOMAIN/api/v1")" ] && pass "its site https://homebox.$DOMAIN/ (logging in through it)" \
    || fail "site: $(ls $P/_nginx/sites; site / | head -c 300)"

echo '== its page'
page_up homebox
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"0.27.1"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://homebox.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["restart_needed"]')" = false ] \
    && [ "$(echo "$ST" | j '$d["admin"]')" = "\"$ADMIN\"" ] && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] \
    && pass 'status: running, Homebox 0.27.1, its site, the admin account and its password' || fail "status: $(echo "$ST" | head -c 400)"
R=$(post new_password -d confirm=1); NEW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && [ -n "$(login $ADMIN "$NEW")" ] && [ -z "$(login $ADMIN "$PW")" ] && [ "$(cat $D/admin_password)" = "$NEW" ] \
    && pass 'a new password from the page (the old one refused)' || fail "new password: $R"
R=$(post reset_link -d email=$ADMIN); LINK=$(echo "$R" | j '$d["link"] ?? ""' | tr -d '"' | sed 's#\\/#/#g')
case "$LINK" in
    "https://homebox.$DOMAIN/reset-password?token="*)
        [ "$(code -H 'Content-Type: application/json' -d "{\"token\":\"${LINK##*token=}\",\"password\":\"Mine-in-Homebox-1\"}" $A/users/reset-password)" = 204 ] \
            && [ -n "$(login $ADMIN Mine-in-Homebox-1)" ] && pass 'a reset link from the page: on its site'"'"'s address, and it works' || fail "reset link: $LINK"
        ;;
    *) fail "reset link: $R" ;;
esac
[ "$(post reset_link -d email=nobody@example.test | j '$d["ok"]')" = false ] && [ "$(post reset_link -d email=not-an-email | j '$d["ok"]')" = false ] \
    && pass 'no reset link for an account that doesn'"'"'t exist, or a wrong address' || fail 'reset link refusals'
restart
[ -n "$(login $ADMIN Mine-in-Homebox-1)" ] && [ "$(curl -s -H "Authorization: $(login $ADMIN Mine-in-Homebox-1)" "$A/entities?q=drill" | grep -c 'Cordless drill')" = 1 ] \
    && pass 'restarted: its password and items kept, no second admin account made' || fail "restart: $(tail -n 5 /tmp/restart.log)"

echo '== the household'
TOKEN=$(login $ADMIN Mine-in-Homebox-1)
INV=$(curl -s -H "Authorization: $TOKEN" -H 'Content-Type: application/json' -d '{"uses":1,"expiresAt":"2099-01-01T00:00:00Z"}' $A/groups/invitations | j '$d["token"] ?? ""' | tr -d '"')
[ -n "$INV" ] && [ "$(signup jane@example.test "$INV")" = 204 ] && [ -n "$(login jane@example.test Some-pass-123)" ] \
    && pass 'an invitation from Homebox works while sign-ups are off' || fail "invitation: $INV"
R=$(post settings -d listen=local -d signups=on -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(signup alice@example.test)" = 204 ] \
    && pass 'sign-ups on from the page' || fail "sign-ups on: $R"
post settings -d listen=local -d signups=off -d backup_keep=14 > /dev/null
[ "$(signup bob@example.test)" = 403 ] && pass 'and off again' || fail 'sign-ups off'

echo '== backups'
R=$(post backup -d confirm=1)
F=$(ls $D/backups/homebox-*.tar.gz 2>/dev/null | head -n 1)
rm -rf /tmp/restore; mkdir -p /tmp/restore && tar -xzf "$F" -C /tmp/restore 2>/dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%a' "$F")" = 600 ] \
    && $P/homebox/binaries/sqlite3 /tmp/restore/homebox.db "SELECT name FROM entities" | grep -q 'Cordless drill' \
    && grep -rq 'Receipt for the drill' /tmp/restore \
    && pass 'a backup from the page, root'"'"'s only, with the item and its attachment in it' || fail "backup: $R $(ls -la $D/backups)"
post settings -d listen=local -d signups=off -d backup_keep=2 > /dev/null
for i in 1 2 3; do sleep 1; sh $P/homebox/homebox_ctl.sh backup > /dev/null 2>&1; done
[ "$(ls $D/backups/homebox-*.tar.gz | wc -l)" = 2 ] && pass 'only the newest 2 kept' || fail "kept: $(ls $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d signups=off -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:7745)' || fail "listen all: $R"
post settings -d listen=local -d signups=off -d backup_keep=14 > /dev/null
! listens_beyond && [ -n "$(login $ADMIN Mine-in-Homebox-1)" ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'homebox-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-homebox.conf ] && [ -f $D/data/homebox.db ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
