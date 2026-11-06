#!/bin/sh
# phpBB from its package (tests/common/nas.sh), on a stand-in for the NAS's MariaDB 10.5 (image.Dockerfile: root over
# the socket, no password, as WD has it), with the PHP app's PHP and the Nginx app (tests/phpbb/with): its database and
# login made in MariaDB (rights on its own database only), the board installed on its first start by phpBB's installer
# (kept out of the board's folder afterwards), PHP's own server as its own user with its workers, only on the NAS itself,
# its address (the Nginx app's site), its private folders refused, logging in through its site, its routes (app.php), a
# new password from the page, backups, the network setting, a new Nginx domain, started before MariaDB (as at boot), a
# restart keeping its data, removal
. /t/common/nas.sh phpbb
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
SOCK=/var/lib/mysql/mysql.sock; DATADIR=/mnt/HD_a4/.@database@
DOMAIN=nas.example.test
BB=$P/phpbb/binaries/phpbb
q() { mysql --socket=$SOCK -uroot -N -e "$1" 2>&1; }
setting_of() { q "SELECT config_value FROM phpbb.phpbb_config WHERE config_name = '$1'"; }
# MariaDB started as WD's startup-mysql does (mysqld_safe as root), and waited for
start_mariadb() {
    (mysqld_safe --user=root --datadir=$DATADIR --socket=$SOCK --bind-address=127.0.0.1 > /dev/null 2>&1 &)
    i=0; until q 'SELECT 1' | grep -q '^1$' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
}
site() { p=$1; shift; curl -sk -m 20 --resolve "phpbb.$DOMAIN:443:127.0.0.1" "$@" "https://phpbb.$DOMAIN$p"; }
# Logs in on its own form through its site (its form token from the login page - phpBB refuses one sent within the
# same second): prints the board index afterwards
login() {
    rm -f /tmp/jar; site '/ucp.php?mode=login' -c /tmp/jar -o /tmp/login.html
    TOKEN=$(sed -n 's/.*name="form_token" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    TIME=$(sed -n 's/.*name="creation_time" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    SID=$(sed -n 's/.*name="sid" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    sleep 2
    site '/ucp.php?mode=login' -b /tmp/jar -c /tmp/jar -o /tmp/login-result.html --data-urlencode "username=$1" --data-urlencode "password=$2" \
        --data-urlencode "form_token=$TOKEN" --data-urlencode "creation_time=$TIME" --data-urlencode "sid=$SID" --data-urlencode 'login=Login' \
        --data-urlencode 'redirect=./index.php'
    site /index.php -b /tmp/jar
}
logged_in() { echo "$1" | grep -q 'mode=logout'; }
children() { awk -v parent="$1" '$4 == parent { print $1 }' /proc/[0-9]*/stat 2>/dev/null; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F99") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo "== WD's MariaDB 10.5, the PHP app's PHP and Nginx"
mkdir -p /var/lib/mysql $DATADIR
mariadb-install-db --user=root --datadir=$DATADIR --auth-root-authentication-method=normal --skip-test-db > /tmp/install-db.log 2>&1
start_mariadb
q 'SELECT VERSION()' | grep -q '^10.5' && pass "MariaDB $(q 'SELECT VERSION()') answering root on its socket" || { fail "MariaDB: $(tail -n 5 /tmp/install-db.log)"; exit 1; }
# The PHP app's PHP, where the app has it (its switch of the NAS's own PHP needs WD's web server)
mkdir -p $P/php && tar -xzf /pkg/php.tar.gz -C $P/php ./binaries/php
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(@file_get_contents($f),true) ?: []; $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start: the board installed'
install_app
wait_port 8089 120 && pass 'answering on 8089' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 15 /tmp/debug_apkg; tail -n 10 $D/server.log)"; exit 1; }
[ "$(setting_of version)" = 3.3.19 ] && [ "$(q "SELECT username FROM phpbb.phpbb_users WHERE user_id = $(cat $D/admin_id)")" = admin ] \
    && [ "$(q "SELECT user_email FROM phpbb.phpbb_users WHERE user_id = $(cat $D/admin_id)")" = admin@nas.local ] \
    && pass "the board installed by phpBB's installer: 3.3.19, its administrator admin (admin@nas.local)" || fail "installed: $(grep phpbb /tmp/debug_apkg | tail -n 8)"
[ -d $BB/install.dist ] && [ ! -e $BB/install ] && ! grep -q 'install directory' /tmp/index.html 2>/dev/null \
    && [ ! -f $D/conf/install.yml ] && pass 'its installer put back aside (the board shows), its answers file gone' || fail "installer: $(ls -d $BB/install* $D/conf/*)"
PID=$(cat /var/run/phpbb.pid)
WORKERS=$(children $PID)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 69 ] && [ "$(echo $WORKERS | wc -w)" = 4 ] \
    && [ -z "$(for w in $WORKERS; do awk '/^Uid:/ && $2 != 69' /proc/$w/status; done)" ] \
    && tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$P/php/binaries/php -n" \
    && pass "PHP's own server on the PHP app's PHP, as its own user (69), with 4 workers" || fail "processes: $(tr '\0' ' ' < /proc/$PID/cmdline) workers: $WORKERS"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
[ "$(stat -c '%U %G %a' $D/conf/config.php)" = 'root phpbb 640' ] && [ "$(stat -c '%U %a' $D/files)" = 'phpbb 700' ] && [ "$(stat -c '%U %a' $D/cache)" = 'phpbb 700' ] \
    && [ "$(stat -c '%U %a' $D/ext)" = 'root 755' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] \
    && [ "$(readlink $BB/config.php)" = $D/conf/config.php ] && [ "$(readlink $BB/images/avatars/upload)" = $D/avatars ] \
    && grep -q "^@define('PHPBB_INSTALLED', true);" $D/conf/config.php \
    && pass "its settings root's (its group reads them), its data its own, its extensions and passwords root's; linked into phpBB's folder" \
    || fail "files: $(stat -c '%n %U %G %a' $D/conf/config.php $D/files $D/cache $D/ext $D/password)"
G=$(q "SHOW GRANTS FOR 'phpbb'@'localhost'")
echo "$G" | grep -q 'GRANT ALL PRIVILEGES ON `phpbb`\.\* TO' && [ "$(echo "$G" | grep 'ON \*\.\*' | grep -cv '^GRANT USAGE ON')" = 0 ] \
    && [ "$(q "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'phpbb'")" = utf8mb4 ] \
    && pass "its login in MariaDB: all rights on its own database (utf8mb4) only" || fail "grants: $G"
[ "$(setting_of server_protocol)$(setting_of server_name):$(setting_of server_port)" = "https://phpbb.$DOMAIN:443" ] && [ "$(setting_of cookie_secure)" = 1 ] \
    && [ "$(setting_of force_server_vars)" = 1 ] && [ -z "$(setting_of cookie_domain)" ] \
    && pass "its address is the Nginx app's site (https://phpbb.$DOMAIN), its cookies secure and for it only" \
    || fail "address: $(setting_of server_protocol)$(setting_of server_name):$(setting_of server_port) secure $(setting_of cookie_secure)"

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8089' $P/_nginx/sites/60-app-phpbb.conf 2>/dev/null && site /index.php -o /tmp/index.html && grep -q 'phpBB' /tmp/index.html \
    && grep -q "https://phpbb.$DOMAIN/" /tmp/index.html && pass "its board index through its site, its links at https://phpbb.$DOMAIN/" || fail "site: $(head -c 300 /tmp/index.html)"
CODES=''
for p in /config.php /cache/ /store/ /files/ /images/avatars/upload/ /includes/constants.php /vendor/autoload.php /phpbb/user.php /install.dist/app.php \
    /bin/phpbbcli.php /config/default/container/services.yml /.htaccess /composer.json '/%63onfig.php' //store/; do
    CODES="$CODES $(site "$p" -o /dev/null -w '%{http_code}')"
done
[ "$(echo $CODES | tr ' ' '\n' | sort -u)" = 403 ] && pass "its private folders and files refused (15 paths, all 403)" || fail "private: $CODES"
[ "$(site /app.php/help/faq -o /dev/null -w '%{http_code}')" = 200 ] && site /app.php/help/faq | grep -qi 'Frequently Asked Questions' \
    && pass 'its routes (app.php/help/faq) answer' || fail "app.php: $(site /app.php/help/faq -o /dev/null -w '%{http_code}')"
PW=$(cat $D/password)
R=$(login admin "$PW")
logged_in "$R" && pass "the administrator logs in on its form through its site" || fail "login: $(grep -o 'class="error"[^<]*' /tmp/login-result.html | head -n 2) $(head -c 200 /tmp/login-result.html)"
site '/viewtopic.php?t=1' -b /tmp/jar | grep -q 'Welcome to phpBB3' && pass "its first topic shows (viewtopic.php)" || fail "topic: $(site '/viewtopic.php?t=1' -b /tmp/jar | head -c 200)"
R=$(login admin wrong-password-1)
logged_in "$R" && fail 'a wrong password worked' || pass 'a wrong password refused'

echo '== its page'
page_up phpbb
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"3.3.19"' ] && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://phpbb.$DOMAIN/\"" ] \
    && pass "the page: phpBB 3.3.19 answering, its database set up, its address https://phpbb.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login admin Brand.New-Password_1)" && ! logged_in "$(login admin "$PW")" \
    && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"
q "UPDATE phpbb.phpbb_users SET username = 'Boss', username_clean = 'boss' WHERE user_id = $(cat $D/admin_id)" > /dev/null
sh $P/phpbb/phpbb_ctl.sh restart > /dev/null 2>&1
R=$(post set_password -d password=Another.Password_2)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && logged_in "$(login Boss Another.Password_2)" \
    && pass "and after its name was changed in phpBB (found by its ID)" || fail "renamed: $R"

echo '== backups'
mkdir -p $D/ext/acme/demo && echo '{}' > $D/ext/acme/demo/composer.json
R=$(post backup_now)
F=$(ls $D/backups/phpbb-*.tar.gz 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] \
    && tar -xzOf "$F" ./phpbb.sql | grep -q 'CREATE TABLE `phpbb_posts`' && tar -tzf "$F" | grep -q '^ext/acme/demo/composer.json$' \
    && tar -tzf "$F" | grep -q '^files/' && pass "a backup from the page (root's only): its database, attachments, avatars and extensions: $(basename "$F")" \
    || fail "backup: $R $(tar -tzf "$F" 2>&1 | head -n 5)"
mkdir -p $V/Public/ForumBackups
post backup_settings -d dir=$V/Public/ForumBackups -d keep=2 > /dev/null
for i in 1 2 3; do sh $P/phpbb/phpbb_ctl.sh backup > /dev/null 2>&1; sleep 1; done
[ "$(ls $V/Public/ForumBackups/phpbb-*.tar.gz 2>/dev/null | wc -l)" = 2 ] && pass 'backups in the folder chosen, the newest 2 kept' || fail "kept: $(ls $V/Public/ForumBackups)"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(setting_of cookie_secure)" = 0 ] \
    && pass 'on the network too (0.0.0.0:8089): its cookies then not secure-only' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && [ "$(setting_of cookie_secure)" = 1 ] && pass 'and back to the NAS only' || fail 'listen local'

echo '== its address changed'
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json home.example.test
post restart > /dev/null
[ "$(setting_of server_name)" = phpbb.home.example.test ] && pass 'a new Nginx domain: its address follows' || fail "new address: $(setting_of server_name)"
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
post restart > /dev/null

echo '== started before MariaDB (as at boot)'
sh $P/phpbb/stop.sh $P/phpbb > /dev/null 2>&1
listening 8089 && fail 'still answering once stopped' || pass 'stopped, with its workers'
mysqladmin --socket=$SOCK -uroot shutdown > /dev/null 2>&1; i=0; while q 'SELECT 1' | grep -q '^1$' && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
mv $D/db_password $D/db_password.old
sh $P/phpbb/start.sh $P/phpbb > /tmp/start.log 2>&1
listening 8089 && fail 'started without MariaDB' || pass 'not started while MariaDB is down (waiting in the background)'
start_mariadb
i=0; until listening 8089 || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
listening 8089 && ! cmp -s $D/db_password $D/db_password.old && grep -q "$(cat $D/db_password)" $D/conf/config.php && logged_in "$(login Boss Another.Password_2)" \
    && pass "started once MariaDB answered (after ${i}s, a new database password in its settings), the board kept" || fail "later: $(tail -n 5 /tmp/debug_apkg)"

E=$(grep -c 'PHP \(Fatal error\|Parse error\|Warning\)' $D/server.log)
[ "$E" = 0 ] && pass "no PHP errors or warnings logged by PHP 8.5's server meanwhile" || fail "PHP errors: $E $(grep 'PHP \(Fatal\|Warning\)' $D/server.log | sort | uniq -c | sort -rn | head -n 3)"

echo '== removal'
finish_app
! grep -q phpbb- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-phpbb.conf ] && [ -d $D/files ] \
    && [ "$(q 'SELECT count(*) FROM phpbb.phpbb_users' | head -n 1)" -ge 1 ] \
    && pass 'its cron lines and site gone, its files and database kept' || fail 'left behind'
