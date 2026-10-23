#!/bin/sh
# The built package's life, as WD's installer runs it (BusyBox sh): install, initialise and start; removal
P=/mnt/HD/HD_a2/Nas_Prog
. /t/bin/setup.sh
ln -sf /t/bb/busybox /tmp/bb/sh
mkdir -p $P/_install/calibre-web /var/spool/cron/crontabs && touch /var/spool/cron/crontabs/root
tar -xzf /pkg/package.tar.gz -C $P/_install/calibre-web
cd $P && sh $P/_install/calibre-web/install.sh $P/_install/calibre-web $P && sh $P/calibre-web/init.sh $P/calibre-web && sh $P/calibre-web/start.sh $P/calibre-web
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/login)" = 200 ] && pass "installed, initialised and started from the package" || { fail "not answering"; tail -20 /tmp/debug_apkg; }
[ "$(grep -c calibre-web /var/spool/cron/crontabs/root)" = 3 ] && pass "cron: $(grep -o 'cw_ctl.sh [a-z]*\|check_update.sh' /var/spool/cron/crontabs/root | tr '\n' ' ')" || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ -L /var/www/apps/calibre-web/index.php ] && [ -L /var/www/apps/calibre-web/api.php ] && pass "management page linked" || fail "page links: $(ls -la /var/www/apps/calibre-web 2>&1)"
sh $P/calibre-web/stop.sh $P/calibre-web; sh $P/calibre-web/clean.sh $P/calibre-web; sh $P/calibre-web/remove.sh $P/calibre-web
[ ! -d $P/calibre-web ] && [ -f $P/_calibre-web/data/app.db ] && [ -f "/mnt/HD/HD_a2/Public/Books/Calibre Library/metadata.db" ] \
	&& ! grep -q calibre-web /var/spool/cron/crontabs/root && [ "$(ps | grep -c '[c]alibreweb -p')" = 0 ] \
	&& pass "removed: app gone, stopped, cron cleaned - its data and the library kept" || fail "remove"
