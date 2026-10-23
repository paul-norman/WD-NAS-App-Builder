#!/bin/sh
# The built package's life, as WD's installer runs it (BusyBox sh): install, initialise and start; removal
P=/mnt/HD/HD_a2/Nas_Prog
. /t/bin/setup.sh
ln -sf /t/bb/busybox /tmp/bb/sh
mkdir -p $P/_install/copyparty /var/spool/cron/crontabs && touch /var/spool/cron/crontabs/root
tar -xzf /pkg/package.tar.gz -C $P/_install/copyparty
cd $P && sh $P/_install/copyparty/install.sh $P/_install/copyparty $P && sh $P/copyparty/init.sh $P/copyparty && sh $P/copyparty/start.sh $P/copyparty
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3923/)" = 200 ] && pass "installed, initialised and started from the package" || { fail "not answering"; tail -20 /tmp/debug_apkg; }
[ "$(grep -c copyparty /var/spool/cron/crontabs/root)" = 2 ] && pass "cron: $(grep -o 'cpp_ctl.sh [a-z]*\|check_update.sh' /var/spool/cron/crontabs/root | tr '\n' ' ')" || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ -L /var/www/apps/copyparty/index.php ] && [ -L /var/www/apps/copyparty/api.php ] && pass "management page linked" || fail "page links: $(ls -la /var/www/apps/copyparty 2>&1)"
[ "$(stat -c '%a' $P/copyparty/cpp_ctl.sh $P/copyparty/lib/cpp_conf.py | tr '\n' ' ')" = "755 644 " ] && [ "$(stat -c '%U' $P/copyparty/manage/api.php)" = root ] \
	&& pass "the app's files: root's, not writable by others" || fail "permissions: $(ls -la $P/copyparty $P/copyparty/lib)"
sh $P/copyparty/stop.sh $P/copyparty; sh $P/copyparty/clean.sh $P/copyparty; sh $P/copyparty/remove.sh $P/copyparty
[ ! -d $P/copyparty ] && [ -f $P/_copyparty/settings.json ] && ! grep -q copyparty /var/spool/cron/crontabs/root \
	&& [ "$(ps | grep -c '[m] copyparty')" = 0 ] && pass "removed: app gone, stopped, cron cleaned - its settings kept" || fail "remove"
