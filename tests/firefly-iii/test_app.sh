#!/bin/sh
# Firefly III from its package (tests/common/nas.sh), on a stand-in for the NAS's MariaDB 10.5 (image.Dockerfile: root
# over the socket, no password, as WD has it), with the PHP app's PHP and the Nginx app (tests/firefly-iii/with): its
# database and login made in MariaDB (rights on its own database only), its first start as its own user on PHP's own
# server with its workers, only on the NAS itself, its owner made before anyone could sign up (and sign-ups then
# refused), its API's keys, logging in through its site, its own daily jobs, a new password from the page, backups, the
# network setting, a new version's database upgrade, started before MariaDB (as at boot), a restart keeping its data,
# removal
. /t/common/nas.sh firefly-iii
# A password with what used to be refused: spaces, quotes, a backslash, ^ & and an accented letter
XPW='Tëst ^&"'"'"'\ pass 1'
# A field of the JSON on the input, decoded (password by default)
jpw() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo isset($d[$argv[1]]) ? $d[$argv[1]] : "";' "${1:-password}"; }
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
SOCK=/var/lib/mysql/mysql.sock; DATADIR=/mnt/HD_a4/.@database@
DOMAIN=nas.example.test
FF=$P/firefly-iii/binaries/firefly
q() { mysql --socket=$SOCK -uroot -N -e "$1" 2>&1; }
# MariaDB started as WD's startup-mysql does (mysqld_safe as root), and waited for
start_mariadb() {
    (mysqld_safe --user=root --datadir=$DATADIR --socket=$SOCK --bind-address=127.0.0.1 > /dev/null 2>&1 &)
    i=0; until q 'SELECT 1' | grep -q '^1$' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
}
site() { p=$1; shift; curl -sk -m 30 --resolve "firefly.$DOMAIN:443:127.0.0.1" "$@" "https://firefly.$DOMAIN$p"; }
# Logs in on its own form through its site (Laravel's CSRF token from the login page): prints the status and where it
# was sent
login() {
    rm -f /tmp/jar; site /login -c /tmp/jar -o /tmp/login.html
    TOKEN=$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    site /login -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' \
        --data-urlencode "_token=$TOKEN" --data-urlencode "email=$1" --data-urlencode "password=$2"
}
# Whether a login went through (sent on into Firefly III, not back to the login form)
logged_in() { echo "$1" | grep -q "^302 https://firefly.$DOMAIN" && ! echo "$1" | grep -q '/login'; }
# The processes whose parent is the one given (PHP's server's workers)
children() { awk -v parent="$1" '$4 == parent { print $1 }' /proc/[0-9]*/stat 2>/dev/null; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F98") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo "== WD's MariaDB 10.5, the PHP app's PHP and Nginx"
mkdir -p /var/lib/mysql $DATADIR
mariadb-install-db --user=root --datadir=$DATADIR --auth-root-authentication-method=normal --skip-test-db > /tmp/install-db.log 2>&1
start_mariadb
q 'SELECT VERSION()' | grep -q '^10.5' && pass "MariaDB $(q 'SELECT VERSION()') answering root on its socket" || { fail "MariaDB: $(tail -n 5 /tmp/install-db.log)"; exit 1; }
# The PHP app's PHP, where the app has it (its switch of the NAS's own PHP needs WD's web server)
mkdir -p $P/php && tar -xzf /pkg/php.tar.gz -C $P/php ./binaries/php
$P/php/binaries/php -v | grep -q '^PHP 8\.5' && pass "the PHP app's PHP: $($P/php/binaries/php -r 'echo PHP_VERSION;')" || fail 'no PHP 8.5'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log; tail -n 15 /tmp/debug_apkg; tail -n 5 $P/_nginx/logs/error.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 8088 300 && pass 'answering on 8088' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 10 $D/server.log; tail -n 20 $D/storage/logs/laravel.log; ps)"; exit 1; }
grep -q 'Firefly III started with PID' /tmp/debug_apkg && ! grep -q 'did not start' /tmp/debug_apkg \
    && pass 'its start found Firefly III answering (its login page)' || fail "start: $(tail -n 5 /tmp/debug_apkg)"
PID=$(cat /var/run/firefly-iii.pid)
WORKERS=$(children $PID)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 55 ] && [ "$(echo $WORKERS | wc -w)" = 4 ] \
    && [ -z "$(for w in $WORKERS; do awk '/^Uid:/ && $2 != 55' /proc/$w/status; done)" ] \
    && tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$P/php/binaries/php -n" \
    && pass "PHP's own server on the PHP app's PHP, as its own user (55), with 4 workers" || fail "processes: $(tr '\0' ' ' < /proc/$PID/cmdline) workers: $WORKERS"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
[ "$(stat -c '%U %G %a' $D/conf/.env)" = 'root firefly 640' ] && [ "$(stat -c '%U %a' $D/storage)" = 'firefly 700' ] \
    && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/app_key)" = '0 600' ] \
    && [ "$(readlink $FF/.env)" = $D/conf/.env ] && [ "$(readlink $FF/storage)" = $D/storage ] \
    && pass "its settings root's (its group reads them), its data its own, its passwords and key root's; linked into Firefly III's folder" \
    || fail "files: $(stat -c '%n %U %G %a' $D/conf/.env $D/storage $D/password $D/db_password $D/app_key)"
[ "$(wc -c < $D/app_key)" = 33 ] && pass 'its key: 32 characters, as Firefly III asks for' || fail "key: $(wc -c < $D/app_key)"
G=$(q "SHOW GRANTS FOR 'firefly'@'localhost'")
echo "$G" | grep -q 'GRANT ALL PRIVILEGES ON `firefly`\.\* TO' && [ "$(echo "$G" | grep 'ON \*\.\*' | grep -cv '^GRANT USAGE ON')" = 0 ] \
    && [ "$(q "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'firefly'")" = utf8mb4 ] \
    && pass "its login in MariaDB: all rights on its own database (utf8mb4) only" || fail "grants: $G"
grep -q "^APP_URL=https://firefly.$DOMAIN$" $D/conf/.env && grep -q '^COOKIE_SECURE=true' $D/conf/.env \
    && grep -q "^DB_SOCKET=$SOCK" $D/conf/.env && grep -q '^TRUSTED_PROXIES=127.0.0.1' $D/conf/.env \
    && pass "its address is the Nginx app's site (https://firefly.$DOMAIN), its cookies secure" || fail "settings: $(grep -E 'APP_URL|SECURE|DB_SOCKET|PROXIES' $D/conf/.env)"
ID=$(cat $D/admin_id)
[ "$(q "SELECT u.email FROM firefly.users u JOIN firefly.role_user ru ON ru.user_id = u.id JOIN firefly.roles r ON r.id = ru.role_id WHERE r.name = 'owner' AND u.id = $ID")" = admin@nas.local ] \
    && [ "$(q 'SELECT count(*) FROM firefly.users')" = 1 ] && [ "$(q "SELECT count(*) FROM firefly.group_memberships WHERE user_id = $ID")" -ge 1 ] \
    && [ -n "$(q "SELECT user_group_id FROM firefly.users WHERE id = $ID" | grep -v NULL)" ] \
    && pass 'its owner admin@nas.local, the only user, with its own financial administration (as its sign-up makes it)' || fail "owner: $(q 'SELECT id, email, user_group_id FROM firefly.users') $(tail -n 5 /tmp/debug_apkg)"
[ "$(stat -c '%u %a' $D/storage/oauth-private.key 2>/dev/null)" = '55 600' ] && [ -s $D/storage/oauth-public.key ] \
    && [ "$(cat $D/db_version)" = 6.7.9 ] \
    && pass "its API's keys made (its own, readable by it only), its database brought up to date for 6.7.9" || fail "keys: $(ls -l $D/storage) $(cat $D/db_version)"
! grep -q '\.ERROR:' $D/storage/logs/laravel.log && pass "no errors in Firefly III's own log after its first start" || fail "errors: $(grep '\.ERROR:' $D/storage/logs/laravel.log | cut -c1-300)"

echo '== logging in, through its site'
PW=$(cat $D/password)
grep -q 'proxy_pass *http://127.0.0.1:8088' $P/_nginx/sites/60-app-firefly.conf 2>/dev/null && R=$(login admin@nas.local "$PW") && logged_in "$R" \
    && site /profile -b /tmp/jar | grep -q 'admin@nas.local' && pass "the owner logs in on its form through its site ($R)" || fail "login: $R $(tail -n 3 $D/server.log; tail -n 5 $D/storage/logs/laravel.log)"
R=$(login admin@nas.local wrong-password-1)
logged_in "$R" && fail "a wrong password worked: $R" || pass 'a wrong password refused'
# Signing up (its form, with its CSRF token): refused, its owner being there
rm -f /tmp/jar; site /register -c /tmp/jar -o /tmp/register.html
TOKEN=$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' /tmp/register.html | head -n 1)
site /register -b /tmp/jar -o /dev/null --data-urlencode "_token=$TOKEN" --data-urlencode 'email=intruder@example.com' \
    --data-urlencode 'password=Some.Long-Password_123456' --data-urlencode 'password_confirmation=Some.Long-Password_123456'
[ "$(q "SELECT count(*) FROM firefly.users WHERE email = 'intruder@example.com'")" = 0 ] && pass 'signing up refused (its owner made first)' || fail 'someone signed up'
[ ! -e $FF/public/storage ] && pass 'its attachments kept out of its public folder' || fail 'public storage link'

echo "== its own daily jobs"
sh $P/firefly-iii/firefly_ctl.sh cron > /tmp/cron.log 2>&1 && [ "$(q "SELECT count(*) FROM firefly.configuration WHERE name LIKE 'last_rt_job%'")" -ge 1 ] \
    && pass "Firefly III's own jobs run (recurring transactions, automatic budgets, bill reminders)" || fail "cron: $(tail -n 5 /tmp/cron.log; q "SELECT name FROM firefly.configuration")"
grep -q 'firefly_ctl.sh daily' /var/spool/cron/crontabs/root && pass 'and daily, from root crontab' || fail 'no daily cron line'

echo '== its page'
page_up firefly-iii
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"6.7.9"' ] && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://firefly.$DOMAIN/\"" ] \
    && pass "the page: Firefly III 6.7.9 answering, its database set up, its address https://firefly.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password --data-urlencode "password=$XPW")
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login admin@nas.local "$XPW")" && ! logged_in "$(login admin@nas.local "$PW")" \
    && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"
q "UPDATE firefly.users SET email = 'me@example.com' WHERE email = 'admin@nas.local'" > /dev/null
R=$(post set_password -d password=Another.Password_2)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login me@example.com Another.Password_2)" \
    && pass "and after its email address was changed in Firefly III (found by its ID)" || fail "changed email: $R"

echo '== backups'
mkdir -p $D/storage/upload && echo 'a receipt' > $D/storage/upload/at-1.data && chown -R 55:55 $D/storage/upload
R=$(post backup_now)
F=$(ls $D/backups/firefly-iii-*.tar.gz 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] \
    && tar -xzOf "$F" ./firefly.sql | grep -q 'CREATE TABLE `users`' && tar -tzf "$F" | grep -q '^\./app_key$' \
    && tar -tzf "$F" | grep -q '^upload/at-1.data$' && tar -tzf "$F" | grep -q '^oauth-private.key$' \
    && pass "a backup from the page (root's only): its database, its keys and its attachments: $(basename "$F")" || fail "backup: $R $(tar -tzf "$F" 2>&1 | head -n 8)"
mkdir -p $V/Public/MoneyBackups
post backup_settings -d dir=$V/Public/MoneyBackups -d keep=2 > /dev/null
for i in 1 2 3; do sh $P/firefly-iii/firefly_ctl.sh backup > /dev/null 2>&1; sleep 1; done
[ "$(ls $V/Public/MoneyBackups/firefly-iii-*.tar.gz 2>/dev/null | wc -l)" = 2 ] && pass 'backups in the folder chosen, the newest 2 kept' || fail "kept: $(ls $V/Public/MoneyBackups)"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q '^COOKIE_SECURE=false' $D/conf/.env \
    && pass 'on the network too (0.0.0.0:8088): its cookies then not secure-only' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && grep -q '^COOKIE_SECURE=true' $D/conf/.env && pass 'and back to the NAS only' || fail 'listen local'

echo '== a new version'
# (As after an update: its database last brought up to date for an earlier version)
echo 6.7.8 > $D/db_version
: > /tmp/debug_apkg
post restart > /dev/null
grep -q 'bringing its database up to date for Firefly III 6.7.9' /tmp/debug_apkg && [ "$(cat $D/db_version)" = 6.7.9 ] \
    && logged_in "$(login me@example.com Another.Password_2)" \
    && pass "its database upgraded by Firefly III's own upgrade, its owner kept" || fail "upgrade: $(tail -n 5 /tmp/debug_apkg)"
: > /tmp/debug_apkg
post restart > /dev/null
! grep -q 'bringing its database up to date' /tmp/debug_apkg && listening 8088 && pass 'and not again at the next start' || fail "upgraded again: $(tail -n 3 /tmp/debug_apkg)"

echo '== started before MariaDB (as at boot)'
sh $P/firefly-iii/stop.sh $P/firefly-iii > /dev/null 2>&1
listening 8088 && fail 'still answering once stopped' || pass 'stopped, with its workers'
mysqladmin --socket=$SOCK -uroot shutdown > /dev/null 2>&1; i=0; while q 'SELECT 1' | grep -q '^1$' && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
mv $D/db_password $D/db_password.old
sh $P/firefly-iii/start.sh $P/firefly-iii > /tmp/start.log 2>&1
listening 8088 && fail 'started without MariaDB' || pass 'not started while MariaDB is down (waiting in the background)'
start_mariadb
i=0; until listening 8088 || [ $i -ge 150 ]; do sleep 3; i=$((i + 3)); done
listening 8088 && ! cmp -s $D/db_password $D/db_password.old && logged_in "$(login me@example.com Another.Password_2)" \
    && [ "$(q 'SELECT count(*) FROM firefly.users')" = 1 ] \
    && pass "started once MariaDB answered (after ${i}s, a new database password), its owner kept" || fail "later: $(tail -n 5 /tmp/debug_apkg)"

echo '== removal'
finish_app
! grep -q firefly-iii- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-firefly.conf ] && [ -f $D/storage/upload/at-1.data ] \
    && [ "$(q 'SELECT count(*) FROM firefly.users' | head -n 1)" -ge 1 ] \
    && pass 'its cron lines and site gone, its files and database kept' || fail 'left behind'
