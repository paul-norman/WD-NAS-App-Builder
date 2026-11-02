#!/bin/sh
# The built package's life, as WD's installer runs it (BusyBox sh): install, initialise and start; removal
P=/mnt/HD/HD_a2/Nas_Prog
. /t/bin/setup.sh
ln -sf /t/bb/busybox /tmp/bb/sh
mkdir -p $P/_install/audiobookshelf /var/spool/cron/crontabs && touch /var/spool/cron/crontabs/root
tar -xzf /pkg/package.tar.gz -C $P/_install/audiobookshelf
cd $P && sh $P/_install/audiobookshelf/install.sh $P/_install/audiobookshelf $P && sh $P/audiobookshelf/init.sh $P/audiobookshelf && sh $P/audiobookshelf/start.sh $P/audiobookshelf
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:13378/status)" = 200 ] && pass 'installed, initialised and started from the package' || { fail 'not answering'; tail -20 /tmp/debug_apkg; }
[ "$(grep -c audiobookshelf /var/spool/cron/crontabs/root)" = 2 ] && pass "cron: $(grep -o 'abs_ctl.sh [a-z]*\|check_update.sh' /var/spool/cron/crontabs/root | tr '\n' ' ')" || fail "cron: $(cat /var/spool/cron/crontabs/root)"
[ -L /var/www/apps/audiobookshelf/index.php ] && [ -L /var/www/apps/audiobookshelf/api.php ] && pass 'management page linked' || fail "page links: $(ls -la /var/www/apps/audiobookshelf 2>&1)"
[ "$(stat -c '%a' $P/audiobookshelf/abs_ctl.sh $P/audiobookshelf/lib/abs.php | tr '\n' ' ')" = '755 644 ' ] && [ "$(stat -c '%U' $P/audiobookshelf/manage/api.php)" = root ] \
    && pass "the app's files: root's, not writable by others" || fail "permissions: $(ls -la $P/audiobookshelf $P/audiobookshelf/lib)"
sh $P/audiobookshelf/stop.sh $P/audiobookshelf; sh $P/audiobookshelf/clean.sh $P/audiobookshelf; sh $P/audiobookshelf/remove.sh $P/audiobookshelf
[ ! -d $P/audiobookshelf ] && [ -f $P/_audiobookshelf/root_password ] && ! grep -q audiobookshelf /var/spool/cron/crontabs/root \
    && [ "$(ps | grep -c '[d]ist-server')" = 0 ] && pass 'removed: app gone, stopped, cron cleaned - its database and root password kept' || fail 'remove'
