#!/bin/sh
# Wiki.js from its package (tests/common/nas.sh), with the PostgreSQL and Nginx apps (tests/wikijs/with): its database
# and login made in PostgreSQL (owning only its database), its first start as its own user, only on the NAS itself, its
# administrator logging in with the page's password (on Wiki.js's own login API, through its site), a new password from
# the page, backups, the network setting, started before PostgreSQL answers (as at boot), a restart keeping its data,
# removal
. /t/common/nas.sh wikijs
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
PGBIN=$P/postgresql/binaries/postgresql/bin
site() { p=$1; shift; curl -sk -m 15 --resolve "wikijs.$DOMAIN:443:127.0.0.1" "$@" "https://wikijs.$DOMAIN$p"; }
# SQL as PostgreSQL's superuser, in Wiki.js's database (or the one given)
q() { PGPASSWORD="$PGPW" $PGBIN/psql -h /var/run/postgresql -U postgres -d "${2:-wikijs}" -X -tA -c "$1" 2>&1; }
# Logs in on Wiki.js's own login API (its site and local login's IDs from its database) - directly, or through its site
# with a third argument: prints its answer
login() {
    SITE=$(q 'SELECT id FROM wiki.sites LIMIT 1'); STRATEGY=$(q "SELECT id FROM wiki.authentication WHERE module = 'local' LIMIT 1")
    BODY="{\"strategyId\": \"$STRATEGY\", \"username\": \"$1\", \"password\": \"$2\"}"
    if [ -n "${3:-}" ]; then
        site "/_api/sites/$SITE/auth/login" -X PUT -H 'Content-Type: application/json' -d "$BODY"
    else
        curl -s -m 15 -X PUT -H 'Content-Type: application/json' "http://127.0.0.1:3010/_api/sites/$SITE/auth/login" -d "$BODY"
    fi
}
authed() { echo "$1" | grep -q '"authenticated":true'; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":0BC2") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with PostgreSQL and Nginx'
install_app postgresql
wait_port 5432 60 && pass 'PostgreSQL answering' || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
page_up postgresql; PGPW=$(post password | j '$d["password"]' | tr -d '"'); D=$P/_wikijs
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 3010 30 && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3010/_ready)" = 200 ] && pass 'answering on 3010 (ready)' \
    || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 20 $D/wikijs.log)"; exit 1; }
PID=$(cat /var/run/wikijs.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 99 ] && pass 'runs as its own user (99)' || fail "user: $(awk '/^Uid:/' /proc/$PID/status)"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
[ "$(stat -c '%U %G %a' $D/conf/config.yml)" = 'root wikijs 640' ] && [ "$(stat -c '%U %a' $D/data)" = 'wikijs 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] \
    && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] && ! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$(cat $D/db_password)" \
    && pass "its configuration root's (its group reads it), its data its own, its passwords root's - none on its command line" \
    || fail "files: $(stat -c '%n %U %G %a' $D/conf/config.yml $D/data $D/password $D/db_password)"
[ "$(q "SELECT rolsuper::text || rolcreatedb::text || rolcreaterole::text FROM pg_roles WHERE rolname = 'wikijs'" postgres)" = falsefalsefalse ] \
    && [ "$(q "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'wikijs'" postgres)" = wikijs ] \
    && [ "$(q "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('ltree', 'pg_trgm')")" = 'ltree,pg_trgm' ] \
    && pass "its login in PostgreSQL (no other rights) owns its database, with the extensions Wiki.js added (ltree, pg_trgm)" \
    || fail "database: $(q "SELECT rolname, rolsuper FROM pg_roles WHERE rolname = 'wikijs'" postgres) $(q 'SELECT extname FROM pg_extension' | tr '\n' ' ')"
[ "$(q "SELECT count(*) FROM wiki.users WHERE email = 'admin@nas.local'")" = 1 ] && [ -s $D/admin_id ] \
    && [ "$(q "SELECT auth::text LIKE '%\"mustChangePwd\": false%' FROM wiki.users WHERE email = 'admin@nas.local'")" = t ] \
    && pass "its administrator: admin@nas.local (no password change asked for)" || fail "administrator: $(q 'SELECT email, auth FROM wiki.users')"

echo '== logging in'
PW=$(cat $D/password)
R=$(login admin@nas.local "$PW")
authed "$R" && pass "the administrator logs in with the app's password" || fail "login: $(echo "$R" | head -c 300)"
R=$(login admin@nas.local wrong-password-1)
! authed "$R" && echo "$R" | grep -q 'ERR_' && pass "a wrong password refused ($(echo "$R" | grep -o 'ERR_[A-Z_]*' | head -n 1))" || fail "wrong password: $(echo "$R" | head -c 200)"
grep -q 'proxy_pass *http://127.0.0.1:3010' $P/_nginx/sites/60-app-wikijs.conf 2>/dev/null && site / | grep -qi 'wiki' \
    && authed "$(login admin@nas.local "$PW" site)" \
    && pass "its site through Nginx (https://wikijs.$DOMAIN): its pages, and logging in" || fail "site: $(ls $P/_nginx/sites; grep -i 'nginx\|sites' /tmp/debug_apkg | tail -n 5; site / | head -c 200)"

echo '== its page'
page_up wikijs
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"3.3.1"' ] && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://wikijs.$DOMAIN/\"" ] \
    && pass "the page: Wiki.js 3.3.1 answering, its database set up, its address https://wikijs.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=short)
[ "$(echo "$R" | j '$d["ok"]')" = false ] && pass 'a short password refused' || fail "short password: $R"
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && authed "$(login admin@nas.local Brand.New-Password_1)" && ! authed "$(login admin@nas.local "$PW")" \
    && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"
q "UPDATE wiki.users SET email = 'me@example.com' WHERE email = 'admin@nas.local'" > /dev/null
R=$(post set_password -d password=Another.Password_2)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && authed "$(login me@example.com Another.Password_2)" \
    && pass "and after its email address was changed in Wiki.js (found by its ID)" || fail "changed email: $R"

echo '== backups'
R=$(post backup_now)
F=$(ls $D/backups/wikijs-*.dump 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] \
    && PGPASSWORD="$PGPW" $PGBIN/pg_restore -l "$F" 2>/dev/null | grep -q 'TABLE DATA wiki users' \
    && pass "a backup of its database from the page (pg_dump, root's only, with its users): $(basename "$F")" || fail "backup: $R $(ls -l $D/backups 2>&1)"
mkdir -p $V/Public/WikiBackups
R=$(post backup_settings -d dir=/tmp/elsewhere -d keep=2)
[ "$(echo "$R" | j '$d["ok"]')" = false ] && pass 'a backup folder outside the shares refused' || fail "folder: $R"
post backup_settings -d dir=$V/Public/WikiBackups -d keep=2 > /dev/null
for i in 1 2 3; do sh $P/wikijs/wikijs_ctl.sh backup > /dev/null 2>&1; sleep 1; done
[ "$(ls $V/Public/WikiBackups/wikijs-*.dump 2>/dev/null | wc -l)" = 2 ] && pass 'backups in the folder chosen, the newest 2 kept' || fail "kept: $(ls $V/Public/WikiBackups)"
grep -q 'wikijs_ctl.sh daily # wikijs-daily' /var/spool/cron/crontabs/root && grep -q 'check_update.sh # wikijs-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in root crontab' || fail "crontab: $(cat /var/spool/cron/crontabs/root)"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q '^bindIP: 0.0.0.0' $D/conf/config.yml \
    && pass 'on the network too (0.0.0.0:3010)' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && pass 'and back to the NAS only' || fail 'listen local'

echo '== started before PostgreSQL (as at boot)'
sh $P/wikijs/stop.sh $P/wikijs > /dev/null 2>&1
sh $P/postgresql/stop.sh $P/postgresql > /dev/null 2>&1
listening 3010 && fail 'still answering once stopped' || pass 'stopped'
# As at boot with nothing kept: its database login made again once PostgreSQL answers
mv $D/db_password $D/db_password.old
sh $P/wikijs/start.sh $P/wikijs > /tmp/start.log 2>&1
sleep 3
listening 3010 && fail 'started without PostgreSQL' || pass 'not started while PostgreSQL is down (waiting in the background)'
sh $P/postgresql/start.sh $P/postgresql > /dev/null 2>&1
i=0; until [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3010/_ready)" = 200 ] || [ $i -ge 120 ]; do sleep 3; i=$((i + 3)); done
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3010/_ready)" = 200 ] && ! cmp -s $D/db_password $D/db_password.old \
    && authed "$(login me@example.com Another.Password_2)" \
    && pass "started once PostgreSQL answered (after ${i}s, a new database password), its administrator kept" || fail "later: $(tail -n 5 /tmp/debug_apkg)"

echo '== removal'
finish_app
! grep -q wikijs- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-wikijs.conf ] && [ "$(q 'SELECT count(*) FROM wiki.users' | head -n 1)" -ge 1 ] \
    && pass 'its cron lines and site gone, its database kept in PostgreSQL' || fail 'left behind'
