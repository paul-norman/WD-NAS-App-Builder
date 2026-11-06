#!/bin/sh
# BookStack from its package (tests/common/nas.sh), on a stand-in for the NAS's MariaDB 10.5 (image.Dockerfile: root
# over the socket, no password, as WD has it), with the PHP app's PHP and the Nginx app (tests/bookstack/with): its
# database and login made in MariaDB (rights on its own database only), its first start as its own user on PHP's own
# server with its workers, only on the NAS itself, its default administrator taken over before anyone could use it, its
# address (the Nginx app's site), logging in through its site, an image kept out of public view, a new password from
# the page, backups, the network setting, started before MariaDB (as at boot), a restart keeping its data, removal
. /t/common/nas.sh bookstack
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
SOCK=/var/lib/mysql/mysql.sock; DATADIR=/mnt/HD_a4/.@database@
DOMAIN=nas.example.test
q() { mysql --socket=$SOCK -uroot -N -e "$1" 2>&1; }
# MariaDB started as WD's startup-mysql does (mysqld_safe as root), and waited for
start_mariadb() {
    (mysqld_safe --user=root --datadir=$DATADIR --socket=$SOCK --bind-address=127.0.0.1 > /dev/null 2>&1 &)
    i=0; until q 'SELECT 1' | grep -q '^1$' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
}
site() { p=$1; shift; curl -sk -m 20 --resolve "bookstack.$DOMAIN:443:127.0.0.1" "$@" "https://bookstack.$DOMAIN$p"; }
# Logs in on its own form through its site (Laravel's CSRF token from the login page): prints the status and where it
# was sent
login() {
    rm -f /tmp/jar; site /login -c /tmp/jar -o /tmp/login.html
    TOKEN=$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    site /login -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' \
        --data-urlencode "_token=$TOKEN" --data-urlencode "email=$1" --data-urlencode "password=$2"
}
# Whether a login went through (sent to its home page, not back to the login form)
logged_in() { echo "$1" | grep -q "^302 https://bookstack.$DOMAIN/\{0,1\}$"; }
# The processes whose parent is the one given (PHP's server's workers)
children() { awk -v parent="$1" '$4 == parent { print $1 }' /proc/[0-9]*/stat 2>/dev/null; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1ADB") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

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
wait_port 6875 240 && pass 'answering on 6875' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 10 $D/server.log; tail -n 20 $D/storage/logs/laravel.log; ps)"; exit 1; }
PID=$(cat /var/run/bookstack.pid)
WORKERS=$(children $PID)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 98 ] && [ "$(echo $WORKERS | wc -w)" = 4 ] \
    && [ -z "$(for w in $WORKERS; do awk '/^Uid:/ && $2 != 98' /proc/$w/status; done)" ] \
    && tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$P/php/binaries/php -n" \
    && pass "PHP's own server on the PHP app's PHP, as its own user (98), with 4 workers" || fail "processes: $(tr '\0' ' ' < /proc/$PID/cmdline) workers: $WORKERS"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
[ "$(stat -c '%U %G %a' $D/conf/.env)" = 'root bookstack 640' ] && [ "$(stat -c '%U %a' $D/storage)" = 'bookstack 700' ] \
    && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/app_key)" = '0 600' ] \
    && [ "$(readlink $P/bookstack/binaries/bookstack/.env)" = $D/conf/.env ] && [ "$(readlink $P/bookstack/binaries/bookstack/storage)" = $D/storage ] \
    && pass "its settings root's (its group reads them), its data its own, its passwords and key root's; linked into BookStack's folder" \
    || fail "files: $(stat -c '%n %U %G %a' $D/conf/.env $D/storage $D/password $D/db_password $D/app_key)"
G=$(q "SHOW GRANTS FOR 'bookstack'@'localhost'")
echo "$G" | grep -q 'GRANT ALL PRIVILEGES ON `bookstack`\.\* TO' && [ "$(echo "$G" | grep 'ON \*\.\*' | grep -cv '^GRANT USAGE ON')" = 0 ] \
    && [ "$(q "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'bookstack'")" = utf8mb4 ] \
    && pass "its login in MariaDB: all rights on its own database (utf8mb4) only" || fail "grants: $G"
grep -q "^APP_URL=https://bookstack.$DOMAIN$" $D/conf/.env && grep -q '^SESSION_SECURE_COOKIE=true' $D/conf/.env \
    && grep -q '^STORAGE_TYPE=local_secure_restricted' $D/conf/.env && grep -q "^DB_SOCKET=$SOCK" $D/conf/.env \
    && pass "its address is the Nginx app's site (https://bookstack.$DOMAIN), its cookies secure, its files private" || fail "settings: $(grep -E 'APP_URL|SECURE|STORAGE|DB_SOCKET' $D/conf/.env)"
[ "$(q "SELECT email FROM bookstack.users u JOIN bookstack.role_user r ON r.user_id = u.id WHERE u.id = $(cat $D/admin_id)")" = admin@nas.local ] \
    && [ "$(q "SELECT count(*) FROM bookstack.users WHERE email = 'admin@admin.com'")" = 0 ] \
    && pass 'its default administrator (admin@admin.com) is now admin@nas.local, with the generated password' || fail "administrator: $(q 'SELECT id, email FROM bookstack.users')"

echo '== logging in, through its site'
PW=$(cat $D/password)
grep -q 'proxy_pass *http://127.0.0.1:6875' $P/_nginx/sites/60-app-bookstack.conf 2>/dev/null && R=$(login admin@nas.local "$PW") && logged_in "$R" \
    && site / -b /tmp/jar | grep -q 'Shelves' && pass "the administrator logs in on its form through its site ($R)" || fail "login: $R $(tail -n 3 $D/server.log)"
R=$(login admin@admin.com password)
logged_in "$R" && fail "BookStack's default login works: $R" || pass "BookStack's default login (admin@admin.com / password) refused"
R=$(login admin@nas.local wrong-password-1)
logged_in "$R" && fail "a wrong password worked: $R" || pass 'a wrong password refused'
# An image in its storage (as an upload puts it): BookStack only shows it to those allowed (none without a login)
mkdir -p $D/storage/uploads/images/gallery/2026-11 && cp $P/bookstack/web/bookstack.png $D/storage/uploads/images/gallery/2026-11/test.png && chown -R 98:98 $D/storage/uploads
[ "$(site /uploads/images/gallery/2026-11/test.png -o /dev/null -w '%{http_code}')" != 200 ] && [ ! -e $P/bookstack/binaries/bookstack/public/uploads/images ] \
    && pass 'its images kept out of its public folder - not shown without a login' || fail "image: $(site /uploads/images/gallery/2026-11/test.png -o /dev/null -w '%{http_code}')"

echo '== its page'
page_up bookstack
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"26.09.2"' ] && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://bookstack.$DOMAIN/\"" ] \
    && pass "the page: BookStack 26.09.2 answering, its database set up, its address https://bookstack.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login admin@nas.local Brand.New-Password_1)" && ! logged_in "$(login admin@nas.local "$PW")" \
    && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"
q "UPDATE bookstack.users SET email = 'me@example.com' WHERE email = 'admin@nas.local'" > /dev/null
R=$(post set_password -d password=Another.Password_2)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login me@example.com Another.Password_2)" \
    && pass "and after its email address was changed in BookStack (found by its ID)" || fail "changed email: $R"

echo '== backups'
R=$(post backup_now)
F=$(ls $D/backups/bookstack-*.tar.gz 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] \
    && tar -xzOf "$F" ./bookstack.sql | grep -q 'CREATE TABLE `users`' && tar -tzf "$F" | grep -q '^\./app_key$' \
    && tar -tzf "$F" | grep -q 'uploads/images/gallery/2026-11/test.png' \
    && pass "a backup from the page (root's only): its database, its key and its images: $(basename "$F")" || fail "backup: $R $(tar -tzf "$F" 2>&1 | head -n 5)"
mkdir -p $V/Public/WikiBackups
post backup_settings -d dir=$V/Public/WikiBackups -d keep=2 > /dev/null
for i in 1 2 3; do sh $P/bookstack/bookstack_ctl.sh backup > /dev/null 2>&1; sleep 1; done
[ "$(ls $V/Public/WikiBackups/bookstack-*.tar.gz 2>/dev/null | wc -l)" = 2 ] && pass 'backups in the folder chosen, the newest 2 kept' || fail "kept: $(ls $V/Public/WikiBackups)"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q '^SESSION_SECURE_COOKIE=false' $D/conf/.env \
    && pass 'on the network too (0.0.0.0:6875): its cookies then not secure-only' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && grep -q '^SESSION_SECURE_COOKIE=true' $D/conf/.env && pass 'and back to the NAS only' || fail 'listen local'

echo '== its address changed'
# A page's content with a link to it (its own address), as BookStack keeps it
q "INSERT INTO bookstack.entity_page_data (page_id, draft, template, revision_count, editor, html, text, markdown) VALUES (9999, 0, 0, 1, 'wysiwyg', '<a href=\"https://bookstack.$DOMAIN/books\">x</a>', 'x', '')" > /dev/null
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json home.example.test
post restart > /dev/null
grep -q '^APP_URL=https://bookstack.home.example.test$' $D/conf/.env && [ "$(q "SELECT count(*) FROM bookstack.entity_page_data WHERE html LIKE '%bookstack.home.example.test/books%'")" = 1 ] \
    && pass 'a new Nginx domain: its address follows, the links in its pages moved with it' || fail "new address: $(grep APP_URL $D/conf/.env) $(q 'SELECT html FROM bookstack.entity_page_data')"
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
post restart > /dev/null

echo '== started before MariaDB (as at boot)'
sh $P/bookstack/stop.sh $P/bookstack > /dev/null 2>&1
listening 6875 && fail 'still answering once stopped' || pass 'stopped, with its workers'
mysqladmin --socket=$SOCK -uroot shutdown > /dev/null 2>&1; i=0; while q 'SELECT 1' | grep -q '^1$' && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
mv $D/db_password $D/db_password.old
sh $P/bookstack/start.sh $P/bookstack > /tmp/start.log 2>&1
listening 6875 && fail 'started without MariaDB' || pass 'not started while MariaDB is down (waiting in the background)'
start_mariadb
i=0; until listening 6875 || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
listening 6875 && ! cmp -s $D/db_password $D/db_password.old && logged_in "$(login me@example.com Another.Password_2)" \
    && pass "started once MariaDB answered (after ${i}s, a new database password), its administrator kept" || fail "later: $(tail -n 5 /tmp/debug_apkg)"

echo '== removal'
finish_app
! grep -q bookstack- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-bookstack.conf ] && [ -d $D/storage/uploads ] \
    && [ "$(q 'SELECT count(*) FROM bookstack.users' | head -n 1)" -ge 1 ] \
    && pass 'its cron lines and site gone, its files and database kept' || fail 'left behind'
