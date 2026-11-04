#!/bin/sh
# redis_exporter from its package (tests/common/nas.sh), with the Valkey and Prometheus apps
# (tests/redis_exporter/with): Valkey's password (in its environment, never on its command line), its own user, only on
# the NAS itself, Prometheus collecting it, the dashboard's metrics there, Valkey's password changed (read again from
# the page), removal
. /t/common/nas.sh redis_exporter
M=http://127.0.0.1:9121/metrics
metrics() { curl -s -m 10 $M; }
vpass() { awk '$1 == "requirepass" { print $2 }' $P/_valkey/valkey.conf; }
vcli() { REDISCLI_AUTH="$(vpass)" $P/valkey/binaries/valkey-cli -h 127.0.0.1 "$@" 2>/dev/null; }
# Waits up to $2 seconds for the exporter to say whether it reached Valkey ($1: 1 or 0)
wait_up() { i=0; until metrics | grep -q "^redis_up $1$" || [ $i -ge "${2:-60}" ]; do sleep 2; i=$((i + 2)); done; metrics | grep -q "^redis_up $1$"; }
prom() { curl -s -m 5 "http://127.0.0.1:9090/api/v1/$1"; }

echo '== with Valkey and Prometheus'
install_app valkey
wait_port 6379 30 && pass 'Valkey answering' || { fail "Valkey: $(tail -n 5 /tmp/start.log)"; exit 1; }
vcli SET suite:key hello > /dev/null
install_app prometheus
wait_port 9090 60 && pass 'Prometheus answering' || { fail "Prometheus: $(tail -n 5 /tmp/start.log)"; exit 1; }

echo '== first start'
install_app
wait_port 9121 30 && pass 'answering on 9121' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
wait_up 1 30 && pass "it reached Valkey with its password: $(metrics | grep '^redis_up') $(metrics | grep '^redis_db_keys{' | head -n 1)" || fail "redis_up: $(metrics | grep '^redis_up') $(tail -n 3 $D/redis_exporter.log)"
PID=$(cat /var/run/redis_exporter.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 91 ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ ! -e $D/credentials ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass "runs as its own user (91); its copy of Valkey's password root's" || fail "users: $(stat -c '%n %u %a' $D $D/password)"
awk 'NR > 1 && $4 == "0A" && index($2, ":23A1") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1)'
# (Its environment, which holds the password, is its own user's and root's to read - the NAS's root reads it, but this
# container's root lacks the capability to read another user's: its owner and mode are checked instead)
! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$(vpass)" && [ "$(stat -c '%u %a' /proc/$PID/environ)" = '91 400' ] \
    && pass "Valkey's password isn't on its command line; its environment (which has it) is its own user's to read" \
    || fail "password: $(tr '\0' ' ' < /proc/$PID/cmdline) / environ: $(stat -c '%u %a' /proc/$PID/environ)"

echo '== Prometheus'
i=0; until prom 'targets?scrapePool=redis' | grep -q '"health":"up"' || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
prom 'targets?scrapePool=redis' | grep -q '"health":"up"' && pass "Prometheus collects it (after ${i}s)" || fail "target: $(prom 'targets?scrapePool=redis' | head -c 300)"
metrics > /tmp/metrics.txt
MISSING=$(php -r '$d = file_get_contents($argv[1]); preg_match_all("/\"expr\": *\"((?:[^\"\\\\]|\\\\.)*)\"/", $d, $e); preg_match_all("/\\b(redis_[a-z_]+)\\b/", implode(" ", $e[1]), $m); $have = file_get_contents($argv[2]);
    foreach (array_unique($m[1]) as $n) { if (!preg_match("/^".$n."[{ ]/m", $have)) { echo $n, " "; } }' $P/redis_exporter/dashboards/valkey.json /tmp/metrics.txt)
[ -z "$MISSING" ] && pass "every metric its dashboard uses is there ($(grep -c '^redis_' /tmp/metrics.txt) redis_ lines)" || fail "the dashboard uses metrics it doesn't give: $MISSING"
grep -q 'namespace' $P/redis_exporter/dashboards/valkey.json && fail "its dashboard still filters on Kubernetes' namespace" || pass "its dashboard has no namespace filter (no such label on the NAS)"

echo "== Valkey's password changed"
NEW=changed$(date +%s)
sed -i "s/^requirepass .*/requirepass $NEW/" $P/_valkey/valkey.conf
sh $P/valkey/stop.sh $P/valkey > /dev/null 2>&1; sh $P/valkey/start.sh $P/valkey > /dev/null 2>&1; wait_port 6379 30
wait_up 0 60 && pass "with the old password it says Valkey is down" || fail "still up: $(metrics | grep '^redis_up')"
page_up redis_exporter
R=$(post login -d confirm=1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cat $D/password)" = "$NEW" ] && wait_up 1 30 && pass "Valkey's password read again from the page: connected" || fail "read again: $R $(metrics | grep '^redis_up')"
ST=$(get status)
[ "$(echo "$ST" | j '$d["connected"]')" = true ] && [ "$(echo "$ST" | j '$d["login"]["state"]')" = '"ok"' ] && [ "$(echo "$ST" | j '$d["database"]')" = true ] \
    && pass 'the page: connected, the password read' || fail "status: $(echo "$ST" | head -c 400)"

echo '== removal'
finish_app
[ ! -f $P/_prometheus/apps.d/redis_exporter-redis.yml ] && ! grep -q redis_exporter-daily /var/spool/cron/crontabs/root \
    && pass 'its scrape job gone from Prometheus, its cron line too' || fail "left: $(ls $P/_prometheus/apps.d)"
