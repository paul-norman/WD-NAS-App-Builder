#!/bin/sh
# The RetroAssembly app from its package (tests/common/nas.sh), with the Nginx app (tests/retroassembly/with): its first
# start as its own user, only on the NAS itself, its admin account made by the app (nobody else can claim it or sign
# up) with the sample games in its library, its site through Nginx, the page (status, the password and a new one that
# signs the old sessions out), an account the admin adds, sign-ups on and off, backups (its database, saves - not the
# games), on the network too and back, removal keeping its data
. /t/common/nas.sh retroassembly
# A password with what used to be refused: spaces, quotes, a backslash, ^ & and an accented letter
XPW='Tëst ^&"'"'"'\ pass 1'
# A field of the JSON on the input, decoded (password by default)
jpw() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo isset($d[$argv[1]]) ? $d[$argv[1]] : "";' "${1:-password}"; }
# Text for inside a JSON string: jstr <text> - its quotes and backslashes escaped
jstr() { php -r 'echo substr(json_encode($argv[1], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 1, -1);' "$1"; }
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
H=http://127.0.0.1:8098
A=$H/api/v1
ADMIN=admin
DB=$D/data/retroassembly.sqlite
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "games.$DOMAIN:443:127.0.0.1" "$@" "https://games.$DOMAIN$p"; }
# Logs in: login <user> <password> [base] - prints its session's token (empty if refused)
login() { curl -sk -m 30 --resolve "games.$DOMAIN:443:127.0.0.1" --data-urlencode "username=$1" --data-urlencode "password=$2" "${3:-$A}/auth/login" | j '$d["session"]["token"] ?? ""' | tr -d '"'; }
# The user a session's token is for: who <token> - prints the user name (empty if none)
who() { curl -s -m 10 -H "Cookie: token=$1" $A/users/current | j '$d["username"] ?? ""' | tr -d '"'; }
# Signs up (without a session): signup <user> - prints the HTTP status
signup() { code -d "username=$1" -d password=Some-pass-123 $A/auth/register; }
# A query on its database (as RetroAssembly's own user would read it)
q() { $P/retroassembly/binaries/sqlite3 -readonly $DB "$1"; }
# Whether it listens beyond the NAS itself (port 8098 = 1FA2)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1FA2") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }
# Restarts it, as at boot
restart() { sh $P/retroassembly/retroassembly_ctl.sh restart > /tmp/restart.log 2>&1; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
curl -s $H/login | grep -q 'RetroAssembly' \
    && pass 'answering on 8098' || { fail "not answering: $(tail -n 10 $D/retroassembly.log; grep retroassembly /tmp/debug_apkg | tail -n 15)"; exit 1; }
PID=$(cat /var/run/retroassembly.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 54 ] && [ "$(stat -c '%U %a' $D/data)" = 'retroassembly 700' ] \
    && [ "$(stat -c '%U %a' $D/admin_password)" = 'root 600' ] && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] && [ -f $DB ] \
    && pass 'runs as its own user (54), its data its own; its password and settings root'"'"'s' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/data)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'only on the NAS itself (127.0.0.1:8098) - with the Nginx app installed' \
    || fail "listens beyond the NAS: $(cat $D/settings)"
grep -q 'retroassembly-daily' /var/spool/cron/crontabs/root && grep -q 'retroassembly-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ -f $D/admin_created ] && [ "$(q 'SELECT username FROM users WHERE status = 1')" = admin ] \
    && pass 'its admin account made, the only one' || fail "accounts: $(q 'SELECT username FROM users')"

echo '== its admin, no one else'
PW=$(cat $D/admin_password)
TOKEN=$(login $ADMIN "$PW")
[ -n "$TOKEN" ] && [ "$(who "$TOKEN")" = admin ] && [ -z "$(login $ADMIN wrong-password)" ] \
    && pass 'its admin logs in with the page'"'"'s password (a wrong one refused)' || fail "admin: $(grep retroassembly /tmp/debug_apkg | tail -n 5)"
[ "$(signup mallory)" = 403 ] && [ "$(q 'SELECT count(*) FROM users')" = 1 ] && pass 'nobody can sign themselves up' || fail "sign-up: $(signup mallory2)"
[ "$(code $H/library)" = 302 ] && [ -z "$(who '')" ] && pass 'its library not shown without logging in' || fail "anonymous library: $(code $H/library)"

echo '== the sample games'
[ "$(q "SELECT group_concat(platform || ':' || game_name || ':' || game_developer, '|') FROM (SELECT * FROM roms WHERE status = 1 ORDER BY file_name)")" \
    = 'nes:Concentration Room:Damian Yerrick|nes:Double Action Blaster Guys:NovaSquirrel|gb:Libbet and the Magic Floor:Damian Yerrick|nes:Thwaite:Damian Yerrick|gbc:µCity:Antonio Niño Díaz' ] \
    && q "SELECT game_description FROM roms WHERE file_name = 'ucity.gbc'" | grep -q 'GPL-3.0-or-later' \
    && pass 'five sample games in its library: names, authors and licenses' || fail "games: $(q 'SELECT file_name, platform, game_name FROM roms'; grep 'sample game' /tmp/debug_apkg)"
ID=$(q "SELECT id FROM roms WHERE file_name = 'thwaite.nes'")
[ "$(curl -s -H "Cookie: token=$TOKEN" "$A/roms/$ID/content" | sha256sum | cut -c1-16)" = a2df24d9c9f72e56 ] \
    && [ "$(find $D/data/storage/roms -type f | wc -l)" = 5 ] \
    && pass 'a game served from its storage, as uploaded' || fail "content: $(find $D/data/storage | head)"
[ "$(code "$A/roms/$ID/content")" != 200 ] && pass 'and not without logging in' || fail 'anonymous game'

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:8098' $P/_nginx/sites/60-app-games.conf 2>/dev/null && site /login | grep -q 'RetroAssembly' \
    && [ -n "$(login $ADMIN "$PW" "https://games.$DOMAIN/api/v1")" ] && pass "its site https://games.$DOMAIN/ (logging in through it)" \
    || fail "site: $(ls $P/_nginx/sites; site /login | head -c 300)"

echo '== its page'
page_up retroassembly
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"7.261011.1345"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://games.$DOMAIN/\"" ] \
    && [ "$(echo "$ST" | j '$d["admin"]')" = '"admin"' ] && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] \
    && pass 'status: running, RetroAssembly 7.261011.1345, its site, the admin account and its password' || fail "status: $(echo "$ST" | head -c 400)"
R=$(post new_password -d confirm=1 --data-urlencode "password=$XPW"); NEW=$(echo "$R" | jpw)
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && [ -n "$(login $ADMIN "$NEW")" ] && [ -z "$(login $ADMIN "$PW")" ] && [ "$(cat $D/admin_password)" = "$NEW" ] \
    && pass 'a new password from the page (the old one refused)' || fail "new password: $R"
[ -z "$(who "$TOKEN")" ] && pass 'its sessions with the old password signed out' || fail "old session: $(who "$TOKEN")"
restart
TOKEN=$(login $ADMIN "$NEW")
[ -n "$TOKEN" ] && [ "$(q 'SELECT count(*) FROM users')" = 1 ] && [ "$(q 'SELECT count(*) FROM roms WHERE status = 1')" = 5 ] \
    && pass 'restarted: its password and games kept, no second admin account or games' || fail "restart: $(tail -n 5 /tmp/restart.log)"

echo '== the household'
R=$(curl -s -H "Cookie: token=$TOKEN" -d username=jane -d password=Janes-pass-123 $A/users)
[ "$(echo "$R" | j '$d["username"] ?? ""')" = '"jane"' ] && [ "$(who "$(login jane Janes-pass-123)")" = jane ] \
    && pass 'an account the admin adds in RetroAssembly works while sign-ups are off' || fail "add an account: $R"
JANE=$(login jane Janes-pass-123)
[ "$(code -H "Cookie: token=$JANE" -d username=eve -d password=Eves-pass-123 $A/users)" = 403 ] \
    && pass 'only the admin adds accounts' || fail 'jane added an account'
R=$(post settings -d listen=local -d signups=on -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(signup alice)" = 200 ] \
    && pass 'sign-ups on from the page' || fail "sign-ups on: $R"
post settings -d listen=local -d signups=off -d backup_keep=14 > /dev/null
[ "$(signup bob)" = 403 ] && pass 'and off again' || fail 'sign-ups off'

echo '== backups'
mkdir -p $D/data/storage/states && echo 'a save state' > $D/data/storage/states/thwaite.state && chown -R retroassembly:retroassembly $D/data/storage/states
R=$(post backup -d confirm=1)
F=$(ls $D/backups/retroassembly-*.tar.gz 2>/dev/null | head -n 1)
rm -rf /tmp/restore; mkdir -p /tmp/restore && tar -xzf "$F" -C /tmp/restore 2>/dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%a' "$F")" = 600 ] \
    && [ "$($P/retroassembly/binaries/sqlite3 /tmp/restore/retroassembly.sqlite 'SELECT count(*) FROM roms WHERE status = 1')" = 5 ] \
    && grep -q 'a save state' /tmp/restore/storage/states/thwaite.state && [ ! -e /tmp/restore/storage/roms ] \
    && pass 'a backup from the page, root'"'"'s only: its database and saves, not the games' || fail "backup: $R $(ls -la $D/backups; find /tmp/restore | head)"
post settings -d listen=local -d signups=off -d backup_keep=2 > /dev/null
for i in 1 2 3; do sleep 1; sh $P/retroassembly/retroassembly_ctl.sh backup > /dev/null 2>&1; done
[ "$(ls $D/backups/retroassembly-*.tar.gz | wc -l)" = 2 ] && pass 'only the newest 2 kept' || fail "kept: $(ls $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d signups=off -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:8098)' || fail "listen all: $R"
post settings -d listen=local -d signups=off -d backup_keep=14 > /dev/null
! listens_beyond && [ -n "$(login $ADMIN "$NEW")" ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'retroassembly-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-games.conf ] && [ -f $DB ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
