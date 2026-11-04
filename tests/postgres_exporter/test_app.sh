#!/bin/sh
# postgres_exporter from its package (tests/common/nas.sh), with the PostgreSQL, Prometheus and Grafana apps
# (tests/postgres_exporter/with): its login in PostgreSQL (pg_monitor, nothing more), its own user, only on the NAS
# itself, no password on its command line, Prometheus collecting it and Grafana showing its dashboard (and both dropping
# them once it's removed), the dashboard's metrics there, a new login from the page, PostgreSQL starting after it (as at
# boot)
. /t/common/nas.sh postgres_exporter
M=http://127.0.0.1:9187/metrics
metrics() { curl -s -m 10 $M; }
# A query as PostgreSQL's superuser
q() { PGPASSWORD="$(cat $P/_postgresql/postgres_password)" $P/postgresql/binaries/postgresql/bin/psql -h /var/run/postgresql -U postgres -d postgres -X -A -t -c "$1" 2>&1; }
# Waits up to $2 seconds for the exporter to say whether it reached PostgreSQL ($1: 1 or 0)
wait_up() { i=0; until metrics | grep -q "^pg_up $1$" || [ $i -ge "${2:-60}" ]; do sleep 2; i=$((i + 2)); done; metrics | grep -q "^pg_up $1$"; }
# Prometheus' API, and Grafana's (as its admin)
prom() { curl -s -m 5 "http://127.0.0.1:9090/api/v1/$1"; }
graf() { curl -s -m 5 -u "admin:$(cat $P/_grafana/admin_password)" "http://127.0.0.1:3000/api/$1"; }

echo '== with PostgreSQL, Prometheus and Grafana'
install_app postgresql
wait_port 5432 60 && pass 'PostgreSQL answering' || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
install_app prometheus
wait_port 9090 60 && pass 'Prometheus answering' || { fail "Prometheus: $(tail -n 5 /tmp/start.log)"; exit 1; }
install_app grafana
wait_port 3000 120 && pass 'Grafana answering' || { fail "Grafana: $(tail -n 5 /tmp/start.log)"; exit 1; }

echo '== first start'
install_app
wait_port 9187 30 && pass 'answering on 9187' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
wait_up 1 30 && pass "it reached PostgreSQL: $(metrics | grep '^pg_up')" || fail "pg_up: $(metrics | grep '^pg_up') $(tail -n 3 $D/postgres_exporter.log)"
R=$(q "SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolconnlimit, pg_has_role('postgres_exporter', 'pg_monitor', 'member'), pg_has_role('postgres_exporter', 'pg_write_all_data', 'member') FROM pg_roles WHERE rolname = 'postgres_exporter'")
[ "$R" = 't|f|f|f|3|t|f' ] && pass "its login: postgres_exporter, in pg_monitor only, at most 3 connections ($R)" || fail "role: $R"
PID=$(cat /var/run/postgres_exporter.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 89 ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/credentials)" = '89 600' ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass "runs as its own user (89); its password root's, its own copy its user's only" || fail "users: $(stat -c '%n %u %a' $D $D/password $D/credentials)"
awk 'NR > 1 && $4 == "0A" && index($2, ":23E3") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1)'
! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$(cat $D/password)" && ! grep -q "$(cat $D/password)" $D/postgres_exporter.log \
    && pass 'its password is on neither its command line nor in its log' || fail "password seen: $(tr '\0' ' ' < /proc/$PID/cmdline)"

echo '== Prometheus and Grafana'
grep -q "instance: '$(hostname)'" $P/_prometheus/apps.d/postgres_exporter-postgres.yml && grep -q "apps.d/\*.yml" $P/_prometheus/prometheus.yml \
    && pass "Prometheus has its scrape job (instance: the NAS's name)" || fail "scrape job: $(ls $P/_prometheus/apps.d 2>&1)"
i=0; until prom 'targets?scrapePool=postgres' | grep -q '"health":"up"' || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
prom 'targets?scrapePool=postgres' | grep -q '"health":"up"' && pass "Prometheus collects it (after ${i}s)" || fail "target: $(prom 'targets?scrapePool=postgres' | head -c 300)"
[ -f $P/_grafana/app-dashboards/postgres_exporter-postgresql.json ] && pass "Grafana has its dashboard's file" || fail "dashboard file: $(ls $P/_grafana/app-dashboards 2>&1)"
i=0; until graf 'search?query=PostgreSQL' | grep -q '"folderTitle":"NAS"' || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
graf 'search?query=PostgreSQL' | grep -q '"folderTitle":"NAS"' && pass "Grafana shows its dashboard, in its NAS folder: $(graf 'search?query=PostgreSQL' | grep -o '"title":"[^"]*"' | head -n 1)" \
    || fail "dashboard: $(graf 'search?query=PostgreSQL' | head -c 300)"
# Every metric its dashboard's queries use, in what it gives
metrics > /tmp/metrics.txt
MISSING=$(php -r '$d = file_get_contents($argv[1]); preg_match_all("/\"expr\": *\"((?:[^\"\\\\]|\\\\.)*)\"/", $d, $e); preg_match_all("/\\b(pg_[a-z_]+)\\b/", implode(" ", $e[1]), $m); $have = file_get_contents($argv[2]);
    foreach (array_unique($m[1]) as $n) { if (!preg_match("/^".$n."[{ ]/m", $have)) { echo $n, " "; } }' $P/postgres_exporter/dashboards/postgresql.json /tmp/metrics.txt)
[ -z "$MISSING" ] && pass "every metric its dashboard uses is there ($(grep -c '^pg_' /tmp/metrics.txt) pg_ lines)" || fail "the dashboard uses metrics it doesn't give: $MISSING"

echo '== its page'
page_up postgres_exporter
ST=$(get status)
[ "$(echo "$ST" | j '$d["connected"]')" = true ] && [ "$(echo "$ST" | j '$d["login"]["state"]')" = '"ok"' ] && [ "$(echo "$ST" | j '$d["prometheus"]["health"]')" = '"up"' ] \
    && [ "$(echo "$ST" | j '$d["grafana"]["path"]')" = "\"/d/$(php -r 'echo json_decode(file_get_contents($argv[1]), true)["uid"];' $P/postgres_exporter/dashboards/postgresql.json)\"" ] \
    && pass "the page: connected, its login set up, Prometheus collecting, a link to its dashboard ($(echo "$ST" | j '$d["grafana"]'))" || fail "status: $(echo "$ST" | head -c 400)"
OLD=$(cat $D/password)
R=$(post login -d confirm=1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cat $D/password)" != "$OLD" ] && wait_up 1 30 && [ "$(q "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres_exporter'")" = 1 ] \
    && pass 'its login set up again from the page: a new password, still connected' || fail "login again: $R"

echo '== PostgreSQL starting after it (as at boot), its login not yet made'
sh $P/postgres_exporter/stop.sh $P/postgres_exporter > /dev/null 2>&1; sh $P/postgresql/stop.sh $P/postgresql > /dev/null 2>&1
q "SELECT 1" | grep -q '^1$' && fail 'PostgreSQL still answering' || true
rm -f $D/password $D/credentials $D/login.status
sh $P/postgres_exporter/start.sh $P/postgres_exporter > /tmp/start.log 2>&1
grep -q 'waiting for PostgreSQL in the background' /tmp/debug_apkg && wait_port 9187 10 && wait_up 0 20 && pass "started without PostgreSQL: answering, saying it's down, waiting in the background" \
    || fail "without PostgreSQL: $(tail -n 3 /tmp/debug_apkg) $(metrics | grep '^pg_up')"
sh $P/postgresql/start.sh $P/postgresql > /dev/null 2>&1
wait_up 1 90 && [ -s $D/password ] && pass "once PostgreSQL answered: its login set up and it restarted, connected ($(cat $D/login.status))" || fail "after PostgreSQL: $(cat $D/login.status 2>&1) $(metrics | grep '^pg_up')"

echo '== removal'
finish_app
i=0; until [ ! -f $P/_prometheus/apps.d/postgres_exporter-postgres.yml ] && [ ! -f $P/_grafana/app-dashboards/postgres_exporter-postgresql.json ] || [ $i -ge 10 ]; do sleep 1; i=$((i + 1)); done
[ ! -f $P/_prometheus/apps.d/postgres_exporter-postgres.yml ] && [ ! -f $P/_grafana/app-dashboards/postgres_exporter-postgresql.json ] && ! grep -q postgres_exporter-daily /var/spool/cron/crontabs/root \
    && pass 'its scrape job and dashboard gone from Prometheus and Grafana, its cron line too' || fail "left: $(ls $P/_prometheus/apps.d $P/_grafana/app-dashboards)"
