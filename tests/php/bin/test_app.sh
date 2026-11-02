#!/bin/sh
# The PHP app from its package, on a stand-in for the NAS's PHP (WD's 7.4, its php-fpm.sh, php.ini and the pages it
# patches - see wd.sh): switching the NAS to PHP 8.5 without a failed request, WD's pages patched (and why they must
# be), php.ini's settings, the page, switching back (php.ini exactly as it was), switching again, falling back to 7.4
# when 8.5 can't serve, removal
P=/mnt/HD/HD_a2/Nas_Prog; D=$P/_php; PAGES=/usr/local/modules/web/pages
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in sh ps; do ln -sf /bin/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
mkdir -p $P/_install/php /mnt/HD/HD_a2/Public /var/spool/cron/crontabs /var/www/apps && touch /var/spool/cron/crontabs/root
sh /t/bin/wd.sh
# A request to one of WD's pages through php-fpm's socket, as the NAS's Apache sends it
page() { SCRIPT_FILENAME=$PAGES/$1 REQUEST_METHOD=GET QUERY_STRING="${2:-}" cgi-fcgi -bind -connect /var/run/php-fpm.socket 2>/dev/null | tr -d '\r' | sed '1,/^$/d'; }
serving() { readlink /proc/$(cat /var/run/php-fpm.pid 2>/dev/null)/exe 2>/dev/null; }
# Waits up to $1 seconds for php-fpm to be the binary $2
wait_serving() { i=0; while [ $i -lt $1 ]; do [ "$(serving)" = "$2" ] && return 0; sleep 1; i=$((i + 1)); done; return 1; }
WD_FPM=/usr/local/modules/usr/sbin/php-fpm
cp /etc/php/php.ini /tmp/php.ini.before

echo "== WD's PHP 7.4 (before)"
[ "$(serving)" = $WD_FPM ] && page cgi_api.php 'a=1' | grep -q '^PHP 7.4.* cgi_api ok query=a=1 ip=127.0.0.1' && pass "the stand-in NAS serves WD's pages with PHP 7.4: $(page cgi_api.php a=1)" || { fail "stand-in: $(serving) $(page cgi_api.php)"; exit 1; }

echo '== switched to PHP 8.5 (installed and started), without a failed request'
APPFPM=$P/php/binaries/php-fpm
tar -xzf /pkg/php.tar.gz -C $P/_install/php
# Requests every 0.1 seconds throughout, as the dashboard keeps polling while it installs
( n=0; f=0; end=$(( $(date +%s) + 25 )); while [ $(date +%s) -lt $end ]; do n=$((n + 1)); page cgi_api.php | grep -q 'cgi_api ok' || f=$((f + 1)); sleep 0.1; done; echo "$n $f" > /tmp/polls ) &
POLLER=$!
cd $P && sh $P/_install/php/install.sh $P/_install/php $P > /tmp/install.log 2>&1 && sh $P/php/init.sh $P/php > /tmp/init.log 2>&1 && sh $P/php/start.sh $P/php > /tmp/start.log 2>&1
wait_serving 60 $APPFPM && pass "php-fpm is now the app's PHP 8.5 ($(serving))" || fail "not switched: $(serving); $(tail -n 8 /tmp/debug_apkg)"
wait $POLLER; set -- $(cat /tmp/polls)
[ "$2" = 0 ] && [ "$1" -gt 50 ] && pass "no failed request during the switch ($1 requests, 0 failed - a graceful reload, not a restart)" || fail "$2 of $1 requests failed during the switch"
[ "$(/usr/bin/php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')" = 8.5 ] && pass "the NAS's /usr/bin/php is PHP 8.5 too" || fail "cli: $(/usr/bin/php -v | head -n 1)"

echo "== WD's pages patched"
page cgi_api.php 'a=2' | grep -q '^PHP 8.5.* cgi_api ok query=a=2 ip=127.0.0.1' && page restSDK/cloudAccess.php | grep -q '^PHP 8.5.* cloudAccess ok' \
    && pass "WD's pages run on PHP 8.5: $(page cgi_api.php a=2) / $(page restSDK/cloudAccess.php)" || fail "pages: $(page cgi_api.php a=2) / $(page restSDK/cloudAccess.php)"
mkdir -p /tmp/orig && cp /usr/local/modules/web/pages/cgi_api.php /tmp/orig/ 2>/dev/null
umount $PAGES/cgi_api.php $PAGES/restSDK/cloudAccess.php 2>/dev/null
O1=$($P/php/binaries/php $PAGES/cgi_api.php 2>&1 | head -n 2); O2=$($P/php/binaries/php $PAGES/restSDK/cloudAccess.php 2>&1 | head -n 2)
mount --bind $P/php/patched/cgi_api.php $PAGES/cgi_api.php; mount --bind $P/php/patched/restSDK/cloudAccess.php $PAGES/restSDK/cloudAccess.php
echo "$O1" | grep -q 'Fatal error' && echo "$O2" | grep -q 'Fatal error' && pass "(without the patches PHP 8.5 stops on them: $(echo "$O1" | grep -o 'Uncaught [A-Za-z]*: [^"]*' | head -n 1 | cut -c1-80))" || fail "the originals don't fail on 8.5: $O1 / $O2"
grep -q 'added by the php app' /etc/php/php.ini && grep -q '^;extension=apcu.so (built into PHP 8.5)' /etc/php/php.ini && grep -q '^register_argc_argv = Off' /etc/php/php.ini \
    && pass "php.ini: the app's settings between its markers, WD's apcu line set aside (built into 8.5)" || fail "php.ini: $(tail -n 12 /etc/php/php.ini)"
echo '<?php trigger_error("a test error", E_USER_WARNING); trigger_error("a deprecation", E_USER_DEPRECATED); echo "logged";' > $PAGES/errors.php
page errors.php > /dev/null; sleep 1
grep -q 'a test error' $D/php-errors.log && ! grep -q 'a deprecation' $D/php-errors.log && pass 'real errors logged to _php/php-errors.log (deprecations left out)' || fail "error log: $(cat $D/php-errors.log 2>&1 | tail -n 3)"

echo '== its page'
echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
(/usr/bin/php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/phpserver.log 2>&1 &)
sleep 1
ST=$(curl -s -H 'Cookie: PHPSESSID=adminsession123' -H 'X-Requested-With: XMLHttpRequest' 'http://127.0.0.1:8080/apps/php/api.php?action=status')
echo "$ST" | grep -q '8\.5' && echo "$ST" | grep -q 'cgi_api.php' && pass "the page's status: PHP 8.5 serving, the patched files" || fail "page: $(echo "$ST" | head -c 300)"

echo '== switched back (stopped), and again'
# Another app's copy over one of WD's pages (as the Store's Apps page is), which must stay
mkdir -p $PAGES/addons; [ -f $PAGES/addons/app.php ] || echo '<?php echo "wd apps";' > $PAGES/addons/app.php
echo '<?php echo "store apps";' > /tmp/store_app.php; mount --bind /tmp/store_app.php $PAGES/addons/app.php
sh $P/php/stop.sh $P/php > /tmp/stop.log 2>&1
wait_serving 60 $WD_FPM && cmp -s /etc/php/php.ini /tmp/php.ini.before && [ "$(awk -v p="$PAGES/" 'index($2, p) == 1 { print $2 }' /proc/mounts)" = "$PAGES/addons/app.php" ] \
    && page cgi_api.php 'a=3' | grep -q '^PHP 7.4.* cgi_api ok query=a=3' && [ "$(readlink /usr/bin/php)" = /usr/local/modules/usr/bin/php ] \
    && pass "back to WD's PHP 7.4: php.ini byte for byte as before, WD's pages unpatched, /usr/bin/php WD's" || fail "restore: $(serving) $(diff /tmp/php.ini.before /etc/php/php.ini | head -n 5)"
sh $P/php/start.sh $P/php > /dev/null 2>&1
wait_serving 60 $APPFPM && page cgi_api.php | grep -q '^PHP 8.5' && [ "$(grep -c 'added by the php app' /etc/php/php.ini)" = 1 ] \
    && pass 'switched to 8.5 again (its settings in php.ini once)' || fail "re-enable: $(serving)"
grep -q 'store apps' $PAGES/addons/app.php && pass "another app's copy of a WD page (the Store's Apps page) kept through both switches" || fail "the other app's page was unmounted"
umount $PAGES/addons/app.php

echo "== falling back to 7.4 when 8.5 can't serve"
sh $P/php/stop.sh $P/php > /dev/null 2>&1; wait_serving 60 $WD_FPM
mv $APPFPM $APPFPM.real
# A php-fpm that answers -v - as the swap checks first - but can't start
printf '#!/bin/sh\n[ "$1" = -v ] && exec %s.real -v\nexit 1\n' $APPFPM > $APPFPM; chmod 755 $APPFPM
sh $P/php/start.sh $P/php > /dev/null 2>&1; sleep 3
wait_serving 60 $WD_FPM && sleep 2 && cmp -s /etc/php/php.ini /tmp/php.ini.before && page cgi_api.php | grep -q '^PHP 7.4' && grep -q 'switching back to PHP 7.4' /tmp/debug_apkg \
    && pass "8.5 couldn't start: back on 7.4 by itself, php.ini as before - the NAS's pages kept working" || fail "fallback: $(serving); $(tail -n 5 /tmp/debug_apkg)"
mv -f $APPFPM.real $APPFPM

echo '== removed'
sh $P/php/start.sh $P/php > /dev/null 2>&1; wait_serving 60 $APPFPM
sh $P/php/stop.sh $P/php > /dev/null 2>&1; sh $P/php/clean.sh $P/php > /dev/null 2>&1; sh $P/php/remove.sh $P/php > /dev/null 2>&1
wait_serving 60 $WD_FPM && [ ! -d $P/php ] && ! grep -q php-log-rotate /var/spool/cron/crontabs/root && cmp -s /etc/php/php.ini /tmp/php.ini.before \
    && page cgi_api.php | grep -q '^PHP 7.4' && pass "removed: WD's PHP 7.4 serving, php.ini as before, cron cleaned" || fail "remove: $(serving)"
