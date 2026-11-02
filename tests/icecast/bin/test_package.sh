#!/bin/sh
# The built package's life, as WD's installer runs it (BusyBox sh): install, initialise and start; removal
P=/mnt/HD/HD_a2/Nas_Prog
. /t/bin/setup.sh
ln -sf /t/bb/busybox /tmp/bb/sh
mkdir -p $P/_install/icecast /var/spool/cron/crontabs && touch /var/spool/cron/crontabs/root
tar -xzf /pkg/package.tar.gz -C $P/_install/icecast
cd $P && sh $P/_install/icecast/install.sh $P/_install/icecast $P && sh $P/icecast/init.sh $P/icecast && sh $P/icecast/start.sh $P/icecast
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8010/status-json.xsl)" = 200 ] && pass 'installed, initialised and started from the package' || { fail 'not answering'; tail -20 /tmp/debug_apkg; }
[ "$(grep -c icecast /var/spool/cron/crontabs/root)" = 2 ] && pass "cron: $(grep -o 'ice_ctl.sh [a-z]*\|check_update.sh' /var/spool/cron/crontabs/root | tr '\n' ' ')" || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ -L /var/www/apps/icecast/index.php ] && [ -L /var/www/apps/icecast/api.php ] && pass 'management page linked' || fail "page links: $(ls -la /var/www/apps/icecast 2>&1)"
[ "$(stat -c '%a' $P/icecast/ice_ctl.sh $P/icecast/manage/api.php | tr '\n' ' ')" = '755 644 ' ] && [ "$(stat -c '%U' $P/icecast/manage/api.php)" = root ] \
    && pass "the app's files: root's, not writable by others" || fail "permissions: $(ls -la $P/icecast $P/icecast/lib)"
sh $P/icecast/stop.sh $P/icecast; sh $P/icecast/clean.sh $P/icecast; sh $P/icecast/remove.sh $P/icecast
[ ! -d $P/icecast ] && [ -f $P/_icecast/settings ] && ! grep -q icecast /var/spool/cron/crontabs/root \
    && [ "$(ps | grep -c '[b]inaries/icecast')" = 0 ] && pass 'removed: app gone, stopped, cron cleaned - its settings kept' || fail 'remove'
