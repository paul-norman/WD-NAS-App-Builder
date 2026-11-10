#!/bin/sh
# The Vikunja app from its package (tests/common/nas.sh), with the Nginx app (tests/vikunja/with): its admin made before
# its first start (its password typed in through a pseudo-terminal, never on a command line), its own user, only on the
# NAS itself, nobody signing themselves up, a project and a task made and read, CalDAV, its site through Nginx with its
# address in Vikunja, the page (status, the password and a new one, users added and given new passwords), a password
# changed in Vikunja kept, sign-ups on and off, backups with the task in them, on the network too and back, removal
. /t/common/nas.sh vikunja
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
V=http://127.0.0.1:3456
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "vikunja.$DOMAIN:443:127.0.0.1" "$@" "https://vikunja.$DOMAIN$p"; }
# Logs in to Vikunja: login <user> <password> [base] - prints the token (empty if refused)
login() { curl -sk -m 10 --resolve "vikunja.$DOMAIN:443:127.0.0.1" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"$2\"}" "${3:-$V}/api/v1/login" | j '$d["token"] ?? ""' | tr -d '"'; }
# Signs up (unauthenticated): register <user> - prints the HTTP status
register() { code -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"email\":\"$1@example.test\",\"password\":\"Some-pass-1234\"}" "$V/api/v1/register"; }
# Whether it listens beyond the NAS itself (port 3456 = 0D80)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":0D80") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
curl -s $V/api/v1/info | grep -q '"version":"v' \
    && pass 'answering on 3456' || { fail "not answering: $(tail -n 10 $D/vikunja.log; grep vikunja /tmp/debug_apkg | tail -n 15)"; exit 1; }
PID=$(cat /var/run/vikunja.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 59 ] && [ "$(stat -c '%U %a' $D/data)" = 'vikunja 700' ] \
    && [ "$(stat -c '%U %G %a' $D/config.yml)" = 'root vikunja 640' ] && [ "$(stat -c '%U %a' $D/admin_password)" = 'root 600' ] \
    && [ "$(stat -c '%U %a' $D/secret)" = 'root 600' ] && [ -f $D/data/vikunja.db ] \
    && pass 'runs as its own user (59), its data its own, its configuration root'"'"'s (its group reads it), the password root'"'"'s' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/data)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'only on the NAS itself (127.0.0.1:3456) - with the Nginx app installed' \
    || fail "listens beyond the NAS: $(cat $D/settings)"
grep -q 'vikunja-daily' /var/spool/cron/crontabs/root && grep -q 'vikunja-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"
! grep -q "$(cat $D/admin_password)" /tmp/debug_apkg $D/vikunja.log $D/config.yml && pass 'its admin password in no log and no configuration' \
    || fail 'the password is in a log'

echo '== its admin, no one else'
PW=$(cat $D/admin_password)
TOKEN=$(login admin "$PW")
[ -n "$TOKEN" ] && [ -z "$(login admin wrong-password)" ] && pass 'its admin logs in with the page'"'"'s password (a wrong one refused)' \
    || fail "admin: $(sh $P/vikunja/vikunja_ctl.sh users)"
[ "$(register mallory)" = 404 ] && pass 'nobody can sign themselves up' || fail "sign-up: $(register mallory2)"
PROJECT=$(curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"title":"House"}' $V/api/v1/projects | j '$d["id"]')
R=$(curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"title":"Fix the gutter"}' "$V/api/v1/projects/$PROJECT/tasks")
curl -s -H "Authorization: Bearer $TOKEN" "$V/api/v1/tasks" | grep -q 'Fix the gutter' && [ "$(code "$V/api/v1/tasks")" = 401 ] \
    && pass 'a project and a task made and read (nothing without logging in)' || fail "task: $PROJECT $R"
[ "$(code -X PROPFIND -u "admin:$PW" -H 'Depth: 0' "$V/dav/")" = 207 ] && [ "$(code -X PROPFIND -H 'Depth: 0' "$V/dav/")" = 401 ] \
    && pass 'CalDAV answers with a login (207), not without (401)' || fail "CalDAV: $(code -X PROPFIND -u "admin:$PW" -H 'Depth: 0' "$V/dav/")"

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:3456' $P/_nginx/sites/60-app-vikunja.conf 2>/dev/null && site / | grep -qi '<title>Vikunja' \
    && [ -n "$(login admin "$PW" "https://vikunja.$DOMAIN")" ] && pass "its site https://vikunja.$DOMAIN/ (logging in through it)" \
    || fail "site: $(ls $P/_nginx/sites; site / | head -c 300)"
[ "$(curl -s $V/api/v1/info | j '$d["frontend_url"]')" = "\"https://vikunja.$DOMAIN/\"" ] && pass 'its address in Vikunja: the site'"'"'s' \
    || fail "address: $(curl -s $V/api/v1/info | head -c 300)"

echo '== its page'
page_up vikunja
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"2.8.0"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://vikunja.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["users"][0]["name"]')" = '"admin"' ] \
    && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] && pass 'status: running, Vikunja 2.8.0, its site, its users, its password' \
    || fail "status: $(echo "$ST" | head -c 400)"
R=$(post new_password -d user=admin); NEW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ ${#NEW} = 20 ] && [ "$NEW" = "$(cat $D/admin_password)" ] && [ -n "$(login admin "$NEW")" ] && [ -z "$(login admin "$PW")" ] \
    && pass 'a new admin password from the page (the old one refused)' || fail "new password: $R"
R=$(post add_user -d name=sam -d email=sam@example.test); SAM=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ ${#SAM} = 20 ] && [ -n "$(login sam "$SAM")" ] && [ "$(get status | j 'count($d["users"])')" = 2 ] \
    && pass 'a user added from the page, with a generated password' || fail "add user: $R"
[ "$(post add_user -d name=sam -d email=sam2@example.test | j '$d["ok"]')" = false ] && [ "$(post add_user -d name='bad name' -d email=x@example.test | j '$d["ok"]')" = false ] \
    && [ "$(post add_user -d name=kim -d email=not-an-email | j '$d["ok"]')" = false ] && pass 'refused: a name taken, a bad name, a bad email' || fail 'bad users accepted'
R=$(post new_password -d user=sam); SAM2=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ ${#SAM2} = 20 ] && [ -n "$(login sam "$SAM2")" ] && [ -z "$(login sam "$SAM")" ] && [ "$(cat $D/admin_password)" = "$NEW" ] \
    && pass 'a new password for that user (the admin'"'"'s left alone)' || fail "user's new password: $R"
TOKEN=$(login admin "$NEW")
curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"old_password\":\"$NEW\",\"new_password\":\"Mine-in-Vikunja-1\"}" $V/api/v1/user/password
sh $P/vikunja/vikunja_ctl.sh restart > /dev/null 2>&1
[ -n "$(login admin Mine-in-Vikunja-1)" ] && pass 'a password changed in Vikunja kept across a restart' || fail "own password: $(tail -n 3 $D/vikunja.log)"

echo '== sign-ups'
R=$(post settings -d listen=local -d signups=1 -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(register alice)" = 200 ] && pass 'turned on from the page: anyone can sign up' || fail "sign-ups on: $R $(register alice2)"
post settings -d listen=local -d signups=0 -d backup_keep=14 > /dev/null
[ "$(register bob)" = 404 ] && pass 'and off again' || fail 'sign-ups still on'

echo '== backups'
R=$(post backup -d confirm=1)
F=$(ls $D/backups/vikunja-*.tar.gz 2>/dev/null | head -n 1)
mkdir -p /tmp/restore && tar -xzf "$F" -C /tmp/restore 2>/dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%a' "$F")" = 600 ] && [ -d /tmp/restore/files ] \
    && $P/vikunja/binaries/sqlite3 /tmp/restore/vikunja.db "SELECT title FROM tasks" | grep -q 'Fix the gutter' \
    && pass 'a backup from the page, root'"'"'s only, with the task and the attachments folder in it' || fail "backup: $R $(ls -la $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d signups=0 -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:3456)' || fail "listen all: $R"
post settings -d listen=local -d signups=0 -d backup_keep=14 > /dev/null
! listens_beyond && [ -n "$(login admin Mine-in-Vikunja-1)" ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'vikunja-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-vikunja.conf ] && [ -f $D/data/vikunja.db ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
