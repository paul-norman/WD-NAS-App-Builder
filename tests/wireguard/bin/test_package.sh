#!/bin/sh
# The built package's life, as WD's installer runs it (BusyBox sh): install, initialise and start; removal
P=/mnt/HD/HD_a2/Nas_Prog
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in sh ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
ln -sf /t/bb/busybox /sbin/ip
export PATH=/tmp/bb:$PATH
mkdir -p $P/_install/wireguard /var/spool/cron/crontabs && touch /var/spool/cron/crontabs/root
tar -xzf /pkg/package.tar.gz -C $P/_install/wireguard
cd $P && sh $P/_install/wireguard/install.sh $P/_install/wireguard $P && sh $P/wireguard/init.sh $P/wireguard && sh $P/wireguard/start.sh $P/wireguard
ip link show wg0 > /dev/null 2>&1 && [ -S /var/run/wireguard/wg0.sock ] && pass 'installed, initialised and started from the package (wg0 up)' || { fail 'no wg0'; tail -20 /tmp/debug_apkg; }
[ "$(stat -c '%a' $P/_wireguard)" = 700 ] && [ "$(stat -c '%a' $P/_wireguard/server_key)" = 600 ] && pass "its data and the NAS's key: root's only" || fail "data permissions: $(ls -la $P/_wireguard)"
[ "$(grep -c wireguard /var/spool/cron/crontabs/root)" = 1 ] && [ -L /usr/bin/wg ] && wg show wg0 > /dev/null && pass 'the weekly update check, and the wg command (wg show works)' || fail "cron / wg: $(cat /var/spool/cron/crontabs/root)"
[ -L /var/www/apps/wireguard/index.php ] && [ -L /var/www/apps/wireguard/api.php ] && pass 'management page linked' || fail "page links: $(ls -la /var/www/apps/wireguard 2>&1)"
sh $P/wireguard/stop.sh $P/wireguard; sh $P/wireguard/clean.sh $P/wireguard; sh $P/wireguard/remove.sh $P/wireguard
[ ! -d $P/wireguard ] && [ -f $P/_wireguard/server_key ] && ! grep -q wireguard /var/spool/cron/crontabs/root && [ ! -e /usr/bin/wg ] \
    && ! ip link show wg0 > /dev/null 2>&1 && pass 'removed: app gone, stopped, cron and wg link cleaned - its keys kept' || fail 'remove'
