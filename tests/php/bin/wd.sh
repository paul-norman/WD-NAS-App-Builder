#!/bin/sh
# Stand-ins for WD's PHP as the NAS has it, from the image's PHP 7.4 - only what the PHP app relies on:
#  - WD's binaries in /usr/local/modules/usr/{bin/php,sbin/php-fpm}, and the RAM links to them (/usr/bin/php,
#    /usr/sbin/php-fpm)
#  - /etc/php/php.ini (with WD's apcu line) and /etc/php/php-fpm.conf (its socket, as Apache uses it)
#  - /usr/sbin/php-fpm.sh: WD's start script - php-fpm started by its name from the PATH, as root (-R); stop; restart
#    (stop, 3 seconds, start); reload (SIGUSR2)
#  - WD's web pages: the three lines the app patches, which PHP 8 refuses to run, in files that print what they did
mkdir -p /usr/local/modules/usr/bin /usr/local/modules/usr/sbin /etc/php /usr/local/modules/web/pages/restSDK
# Not the image's own PHP settings: its extension list - e.g. sodium - is for its PHP, not the app's, and the NAS has none
rm -rf /usr/local/etc/php/conf.d
cp /usr/local/bin/php /usr/local/modules/usr/bin/php
cp /usr/local/sbin/php-fpm /usr/local/modules/usr/sbin/php-fpm
ln -sf /usr/local/modules/usr/bin/php /usr/bin/php
ln -sf /usr/local/modules/usr/sbin/php-fpm /usr/sbin/php-fpm
cat > /etc/php/php.ini <<'INI'
[PHP]
; WD's php.ini (the parts that matter here)
extension=apcu.so
date.timezone = Europe/London
session.save_path = /tmp
display_errors = Off
INI
cat > /etc/php/php-fpm.conf <<'CONF'
[global]
pid = /var/run/php-fpm.pid
error_log = /tmp/php-fpm.log
daemonize = yes
process_control_timeout = 60
[www]
user = root
group = root
listen = /var/run/php-fpm.socket
pm = static
pm.max_children = 3
CONF
cat > /usr/sbin/php-fpm.sh <<'SH'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
start() { php-fpm -R -c /etc/php/php.ini -y /etc/php/php-fpm.conf; }
stop() {
	pid="$(cat /var/run/php-fpm.pid 2>/dev/null)"
	[ -n "${pid}" ] && kill "${pid}" 2>/dev/null
	for i in 1 2 3 4 5; do kill -0 "${pid}" 2>/dev/null || break; sleep 1; done
	rm -f /var/run/php-fpm.pid
}
case "$1" in
	start) start ;;
	stop) stop ;;
	restart) stop; sleep 3; start ;;
	reload) kill -USR2 "$(cat /var/run/php-fpm.pid)" ;;
esac
SH
chmod +x /usr/sbin/php-fpm.sh
cat > /usr/local/modules/web/pages/cgi_api.php <<'PHP'
<?php
// Stand-in for WD's cgi_api.php: the two lines the PHP app patches, as WD wrote them
$query = $_SERVER[QUERY_STRING];
$r->ip_address = gethostbyname('localhost');
echo 'PHP ' . PHP_VERSION . ' cgi_api ok query=' . $query . ' ip=' . $r->ip_address;
PHP
cat > /usr/local/modules/web/pages/restSDK/cloudAccess.php <<'PHP'
<?php
// Stand-in for WD's restSDK/cloudAccess.php: the line the PHP app patches, as WD wrote it - the token is a string
$id_token = 'a-token';
if(array_key_exists('statusCode', $id_token)) {
	echo 'error';
}
echo 'PHP ' . PHP_VERSION . ' cloudAccess ok';
PHP
/usr/sbin/php-fpm.sh start
