#!/bin/sh
# Uptime Kuma from its package (tests/common/nas.sh): its first start (no setup questions - SQLite chosen), the admin
# account as the browser creates it, ping monitors as its own user (the kernel's unprivileged pings turned on for its
# group only, and off again when it stops - "1 0" on the NAS), the page's password reset, backups, where it listens,
# removal
. /t/common/nas.sh uptime-kuma
export NODE_PATH=$P/uptime-kuma/binaries/uptime-kuma/node_modules
kuma() { $P/uptime-kuma/binaries/node /t/app/kuma.js "$@"; }
RANGE=/proc/sys/net/ipv4/ping_group_range
# Whether a port is listened on only by 127.0.0.1
local_only() { awk -v port=":$(printf '%04X' "$1")" 'NR > 1 && $4 == "0A" && index($2, port) { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && return 1; listening "$1"; }

echo '== first start'
echo '1 0' > $RANGE
install_app
wait_port 3001 120 && pass 'answering on 3001' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 $D/uptime-kuma.log)"; exit 1; }
page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"2.5.9"' ] && [ "$(echo "$ST" | j '$d["user"]')" = '""' ] && [ "$(echo "$ST" | j '$d["answering"]')" = true ] \
    && pass 'the page: Uptime Kuma 2.5.9 answering, no account yet' || fail "status: $(echo "$ST" | head -c 300)"
U=$(awk '/^Uid:/ { print $2 }' /proc/$(cat /var/run/uptime-kuma.pid)/status)
[ "$U" = 72 ] && [ "$(stat -c '%u %a' $D/data)" = '72 700' ] && [ "$(stat -c '%a' $D/settings)" = 600 ] \
    && pass 'runs as its own user (72), its data its own' || fail "user: $U $(stat -c '%u %a' $D/data)"

echo '== the admin account (as the browser creates it)'
[ "$(kuma setup admin 'First-Passw0rd')" = ok ] && [ "$(kuma login admin 'First-Passw0rd')" = ok ] && [ "$(kuma login admin wrong)" != ok ] \
    && [ "$(get status | j '$d["user"]')" = '"admin"' ] && pass 'set up with SQLite (no database questions); its login works, the page shows it' || fail "setup: $(kuma login admin 'First-Passw0rd')"

echo '== ping monitors'
[ "$(cat $RANGE | tr -s ' \t' '  ')" = '72 72' ] && pass 'unprivileged pings turned on for its group only (ping_group_range 72 72)' || fail "range: $(cat $RANGE)"
R=$(kuma ping admin 'First-Passw0rd' 127.0.0.1)
echo "$R" | grep -q '^1 ' && pass "a ping monitor is up: $R" || fail "ping monitor: $R $(tail -n 5 $D/uptime-kuma.log)"

echo '== password reset'
NP=$(post reset_password | j '$d["password"]' | tr -d '"')
[ ${#NP} -ge 16 ] && [ "$(kuma login admin "$NP")" = ok ] && [ "$(kuma login admin 'First-Passw0rd')" != ok ] && ! ps -ef | grep -v grep | grep -q -- "$NP" \
    && pass "a new password from the page works, the old one doesn't (never on a command line)" || fail "reset: $NP $(kuma login admin "$NP")"

echo '== backups'
post backup_settings -d dir=/etc -d keep=2 | grep -q 'volumes' && pass 'a backup folder outside the volumes refused' || fail 'backup folder check'
mkdir -p $V/Backups; post backup_settings -d dir=$V/Backups/Kuma -d keep=2 > /dev/null

for i in 1 2 3; do post backup_now > /dev/null; sleep 1; done
set -- $V/Backups/Kuma/uptime-kuma-*.tar.gz
mkdir -p /tmp/restore && tar -xzf "$1" -C /tmp/restore
[ $# = 2 ] && [ "$(stat -c '%a' "$1")" = 600 ] && [ "$($P/uptime-kuma/binaries/sqlite3 /tmp/restore/kuma.db 'SELECT name FROM monitor;')" = 'the NAS' ] \
    && pass "backups while it runs: a consistent database with the monitor, only the newest 2 kept, root's only" || fail "backups: $# $(ls -l $V/Backups/Kuma)"

echo '== where it listens'
post listen -d listen=local > /dev/null; sleep 2; wait_port 3001 60
local_only 3001 && [ "$(kuma login admin "$NP")" = ok ] && pass 'only the NAS itself (127.0.0.1, for the Nginx app); the data kept' || fail "listen local: $(cat /proc/net/tcp | grep ':0BB9')"
post listen -d listen=all > /dev/null; sleep 2; wait_port 3001 60
! local_only 3001 && pass '...and the whole network again' || fail 'listen all'

echo '== stopped'
sh $P/uptime-kuma/stop.sh $P/uptime-kuma > /dev/null 2>&1
! listening 3001 && [ "$(cat $RANGE | tr -s ' \t' '  ')" = '1 0' ] && pass 'stopped: unprivileged pings off again (1 0, as the NAS has them)' || fail "stop: $(cat $RANGE)"

echo '== removed'
finish_app
