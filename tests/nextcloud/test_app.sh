#!/bin/sh
# Nextcloud from its package (tests/common/nas.sh), with the PostgreSQL, PHP and Nginx apps (tests/nextcloud/with): its
# database and login made in PostgreSQL, installed on its first start with the page's administrator password, its own
# web server and PHP as its own user (not root), only on the NAS itself, files uploaded and downloaded over WebDAV
# through its site (HTTPS, as Nextcloud's own clients do), its background jobs from cron, files found that were added
# outside it, a new password, backups, the network setting, a restart keeping its files, removal
. /t/common/nas.sh nextcloud
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
PGBIN=$P/postgresql/binaries/postgresql/bin
site() { p=$1; shift; curl -sk -m 60 --resolve "nextcloud.$DOMAIN:443:127.0.0.1" "$@" "https://nextcloud.$DOMAIN$p"; }
# WebDAV as admin (with a password - default: the app's): dav <path> [curl options]
dav() { p=$1; shift; site "/remote.php/dav/files/admin$p" -u "admin:${PW:-$(cat $D/password)}" "$@"; }
q() { PGPASSWORD="$PGPW" $PGBIN/psql -h /var/run/postgresql -U postgres -d "${2:-nextcloud}" -X -tA -c "$1" 2>&1; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1FA1") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with PostgreSQL, PHP and Nginx'
install_app postgresql
wait_port 5432 60 && pass 'PostgreSQL answering' || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
page_up postgresql; PGPW=$(post password | j '$d["password"]' | tr -d '"'); D=$P/_nextcloud
# The PHP app's programs, where the app has them (its switch of the NAS's own PHP needs WD's web server)
mkdir -p $P/php && tar -xzf /pkg/php.tar.gz -C $P/php ./binaries/php ./binaries/php-fpm
$P/php/binaries/php -v | grep -q '^PHP 8\.5' && pass "the PHP app's PHP: $($P/php/binaries/php -r 'echo PHP_VERSION;')" || fail 'no PHP 8.5'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start: installed'
install_app
wait_port 8097 30 && curl -s -m 30 http://127.0.0.1:8097/status.php | grep -q '"installed":true' \
    && pass "installed and answering on 8097: $(curl -s http://127.0.0.1:8097/status.php | j '$d["versionstring"]')" \
    || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 5 $D/logs/nginx-error.log $D/logs/php-fpm.log $D/logs/nextcloud.log 2>&1 | cut -c1-300)"; exit 1; }
[ "$(q "SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = 'nextcloud'" postgres)" = f ] \
    && [ "$(q "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'nextcloud'" postgres)" = nextcloud ] && [ "$(q 'SELECT count(*) > 50 FROM oc_appconfig')" = t ] \
    && pass "its database in PostgreSQL: nextcloud, owned by its own login (nothing more), its tables made" || fail "database: $(q "SELECT rolname FROM pg_roles" postgres | tr '\n' ' ')"
NPID=$(cat /var/run/nextcloud-nginx.pid); FPID=$(cat /var/run/nextcloud-php-fpm.pid)
FWORKERS=$(for f in /proc/[0-9]*/stat; do awk -v p=$FPID '$4 == p { print $1 }' $f 2>/dev/null; done | head -n 1)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$NPID/status)" = 64 ] && [ "$(awk '/^Uid:/ { print $2 }' /proc/$FPID/status)" = 64 ] \
    && tr '\0' ' ' < /proc/$NPID/cmdline | grep -q nextcloud-nginx && tr '\0' ' ' < /proc/$FPID/cmdline | grep -q 'nextcloud-php-fpm\|php-fpm: master' \
    && pass "its web server (nextcloud-nginx) and PHP (nextcloud-php-fpm) run as its own user (64), not root" \
    || fail "processes: $(tr '\0' ' ' < /proc/$NPID/cmdline) / $(tr '\0' ' ' < /proc/$FPID/cmdline) $(grep -h '^Uid:' /proc/$NPID/status /proc/$FPID/status | tr '\n' ' ')"
! listens_beyond && pass 'only on the NAS itself (127.0.0.1:8097) - with the Nginx app installed' || fail 'listens beyond the NAS'
[ "$(stat -c '%U %a' $D/data)" = 'nextcloud 770' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] \
    && [ "$(stat -c '%U %a' $D/config)" = 'nextcloud 750' ] && grep -q "'datadirectory' => '$D/data'" $D/config/nas.config.php \
    && pass "its files and configuration its own, the passwords root's, its settings kept by the app (nas.config.php)" || fail "files: $(ls -la $D)"
grep -q 'nextcloud-cron' /var/spool/cron/crontabs/root && [ "$(sh $P/nextcloud/nextcloud_ctl.sh occ config:app:get core backgroundjobs_mode)" = cron ] \
    && pass 'its background jobs from cron, every 5 minutes' || fail "cron: $(sh $P/nextcloud/nextcloud_ctl.sh occ config:app:get core backgroundjobs_mode)"

echo '== its site, WebDAV and logins'
grep -q 'proxy_pass *http://127.0.0.1:8097' $P/_nginx/sites/60-app-nextcloud.conf 2>/dev/null && site /status.php | grep -q '"installed":true' \
    && pass "its site https://nextcloud.$DOMAIN/" || fail "site: $(ls $P/_nginx/sites; site /status.php | head -c 200)"
C=$(site /login -o /dev/null -w '%{http_code}'); L=$(site /login | grep -c 'login-form\|id="body-login"')
[ "$C" = 200 ] && [ "$L" -gt 0 ] && pass 'its login page through its site (the address trusted: no "untrusted domain")' || fail "login page: $C $(site /login | grep -io 'untrusted[^<]*' | head -n 1)"
[ "$(dav / -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}' -u admin:wrong-password)" = 401 ] && pass 'a wrong password refused' || fail 'wrong password'
head -c 2000000 /dev/urandom > /tmp/upload.bin
C=$(dav /test-upload.bin -T /tmp/upload.bin -o /dev/null -w '%{http_code}')
[ "$C" = 201 ] && dav /test-upload.bin -o /tmp/download.bin && cmp -s /tmp/upload.bin /tmp/download.bin && [ -f $D/data/admin/files/test-upload.bin ] \
    && pass "a file uploaded and downloaded over WebDAV through its site, as its clients do ($C), kept in its data folder" || fail "upload: $C $(tail -n 3 $D/logs/nextcloud.log | cut -c1-300)"
R=$(site '/ocs/v2.php/cloud/capabilities?format=json' -u "admin:$(cat $D/password)" -H 'OCS-APIRequest: true')
echo "$R" | grep -q '"version":{"major":35' && pass "its API with the administrator's login (OCS: Nextcloud 35's capabilities)" || fail "ocs: $(echo "$R" | head -c 200)"
site /remote.php/dav/files/admin/ -X PROPFIND -H 'Depth: 1' -u "admin:$(cat $D/password)" | grep -q 'test-upload.bin' \
    && [ "$(site /.well-known/caldav -o /dev/null -w '%{http_code} %{redirect_url}')" = "301 https://nextcloud.$DOMAIN/remote.php/dav/" ] \
    && pass 'its folder listing, and calendars / contacts found at their well-known addresses' || fail "propfind / well-known: $(site /.well-known/caldav -o /dev/null -w '%{http_code} %{redirect_url}')"
[ "$(site /data/admin/files/test-upload.bin -o /dev/null -w '%{http_code}')" = 404 ] && [ "$(site /config/config.php -o /dev/null -w '%{http_code}')" = 404 ] \
    && pass 'its data and configuration folders never served' || fail 'data or config served'

echo '== background jobs, and files added outside it'
LAST=$(q "SELECT configvalue FROM oc_appconfig WHERE appid = 'core' AND configkey = 'lastcron'")
sleep 1; sh $P/nextcloud/nextcloud_ctl.sh cron
[ "$(q "SELECT configvalue FROM oc_appconfig WHERE appid = 'core' AND configkey = 'lastcron'")" -gt "${LAST:-0}" ] && [ ! -d /var/run/nextcloud-cron ] \
    && pass 'its background jobs run (cron.php, as its user)' || fail "cron: $(tail -n 5 $D/logs/cron.log)"
echo 'added outside' > $D/data/admin/files/outside.txt; chown 64:1000 $D/data/admin/files/outside.txt
page_up nextcloud
R=$(post scan -d confirm=1); i=0
while [ $i -lt 30 ] && ! dav / -X PROPFIND -H 'Depth: 1' | grep -q outside.txt; do sleep 2; i=$((i + 1)); done
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(dav /outside.txt)" = 'added outside' ] && pass 'a file put in its data folder some other way, found from the page (Find new files)' || fail "scan: $R"

echo '== its page'
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && echo "$ST" | j '$d["version"]' | grep -q '"35\.' && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://nextcloud.$DOMAIN/\"" ] && pass "status: running, $(echo "$ST" | j '$d["version"]'), its database, its site" \
    || fail "status: $(echo "$ST" | head -c 500)"
[ "$(post password | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the page shows the password' || fail 'password not shown'
OLD=$(cat $D/password); R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(PW=Brand.New-Password_1 dav / -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}')" = 207 ] \
    && [ "$(PW=$OLD dav / -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%{http_code}')" = 401 ] && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"

echo '== backups'
R=$(post backup_now -d confirm=1); F=$(ls $D/backups/nextcloud-*.dump 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] && $PGBIN/pg_restore -l "$F" | grep -q 'TABLE DATA public oc_filecache' \
    && pass "a backup of its database from the page (pg_dump, root's only): $(basename "$F")" || fail "backup: $R"

echo '== the network setting'
R=$(post listen -d listen=all); wait_port 8097 60
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p') \
    && curl -s -m 30 "http://$IP:8097/status.php" | grep -q '"installed":true' && curl -s -m 30 "http://$IP:8097/login" | grep -q 'body-login\|login-form' \
    && pass "on the network too: http://$IP:8097 (its address trusted)" || fail "listen all: $R $(curl -s -m 10 "http://$IP:8097/login" | grep -io 'untrusted[^<]*' | head -n 1)"
post listen -d listen=local > /dev/null; wait_port 8097 60
! listens_beyond && [ "$(dav /test-upload.bin -o /dev/null -w '%{http_code}' -u admin:Brand.New-Password_1)" = 200 ] \
    && pass 'back to the NAS only - its files kept across the restarts' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'nextcloud-' /var/spool/cron/crontabs/root && [ ! -f /var/run/nextcloud-nginx.pid ] && [ -f $D/data/admin/files/test-upload.bin ] && [ ! -f $P/_nginx/sites/60-app-nextcloud.conf ] \
    && pass 'its cron lines and site gone, stopped, its files kept' || fail "left behind: $(ls /var/run 2>&1)"
finish_app nginx
