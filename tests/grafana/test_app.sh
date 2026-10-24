#!/bin/sh
# The monitoring apps together, from their packages (tests/common/nas.sh), installed in the README's order - Node
# Exporter, Prometheus, Loki, Grafana - and wiring themselves up: Node Exporter's password handed to Prometheus, which
# scrapes it; the apps' logs (root's only, too) collected into Loki by Vector; Grafana's data sources and dashboards
# provisioned for both. Then Grafana's page (password reset, backups), and removing them all
. /t/common/nas.sh grafana
PROM=http://127.0.0.1:9090; LOKI=http://127.0.0.1:3100; G=http://127.0.0.1:3000
# Prometheus's and Loki's query APIs: the number of results for a query
promq() { curl -s --data-urlencode "query=$1" $PROM/api/v1/query | j 'count($d["data"]["result"] ?? [])'; }
lokiq() { curl -s -G --data-urlencode "query=$1" --data-urlencode "since=1h" --data-urlencode "limit=5" $LOKI/loki/api/v1/query_range | j 'count($d["data"]["result"] ?? [])'; }

echo "== Node Exporter, with its password"
install_app node_exporter
wait_port 9100 60 && page_up node_exporter
post settings -d port=9100 -d auth=1 > /dev/null; wait_port 9100 30; sleep 1
NEPW=$(post password | j '$d["password"]' | tr -d '"')
[ "$(code http://127.0.0.1:9100/metrics)" = 401 ] && [ "$(code -u prometheus:$NEPW http://127.0.0.1:9100/metrics)" = 200 ] \
	&& pass "Node Exporter's metrics need its password" || fail "node exporter auth: $(code -u prometheus:$NEPW http://127.0.0.1:9100/metrics)"

echo "== Prometheus, wired to it"
install_app prometheus
wait_port 9090 60 && page_up prometheus
i=0; while [ $i -lt 60 ] && [ "$(promq 'up == 1')" != 2 ]; do sleep 2; i=$((i + 1)); done
ST=$(get status)
[ "$(promq 'up{job="node"} == 1')" = 1 ] && [ "$(promq 'up{job="prometheus"} == 1')" = 1 ] && [ "$(echo "$ST" | j '$d["config_ok"]')" = true ] \
	&& pass "it scrapes Node Exporter (with its password) and itself: $(echo "$ST" | j 'implode(", ", array_map(function ($t) { return $t["job"] . " " . $t["health"]; }, $d["targets"]))')" \
	|| fail "targets: $(echo "$ST" | j '$d["targets"]' | head -c 300)"
[ "$(stat -c '%u %a' $P/_prometheus/node_exporter.password)" = "73 600" ] && [ "$(promq "node_uname_info{instance=\"$(hostname)\"}")" = 1 ] \
	&& pass "the password copied for its user only; the NAS named by its hostname ($(hostname))" || fail "copy/instance: $(stat -c '%u %a' $P/_prometheus/node_exporter.password)"
awk 'NR > 1 && $4 == "0A" && index($2, ":2382") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv "^0100007F:" && fail "Prometheus listens beyond the NAS" \
	|| pass "Prometheus only on the NAS itself (127.0.0.1:9090 - it has no login)"
page_up node_exporter > /dev/null; post set_password > /dev/null; wait_port 9100 30; sleep 35
[ "$(promq 'up{job="node"} == 1')" = 1 ] && pass "a new Node Exporter password reaches Prometheus too" || fail "after the new password: $(curl -s $PROM/api/v1/targets | head -c 300)"
page_up prometheus > /dev/null
echo 'scrape_configs: [ {job_name: broken' > $P/_prometheus/scrape.d/broken.yml
R=$(post reload)
echo "$R" | grep -q "kept the previous one" && [ "$(promq 'up{job="node"} == 1')" = 1 ] && pass "a broken file of your own: refused, the working configuration kept" || fail "reload: $R"
rm -f $P/_prometheus/scrape.d/broken.yml; post reload > /dev/null

echo "== Loki, collecting the logs"
install_app loki
wait_port 3100 60 && page_up loki
i=0; while [ $i -lt 60 ] && [ "$(lokiq '{source="app", app="prometheus"}')" = 0 ]; do sleep 2; i=$((i + 1)); done
[ "$(lokiq '{source="app", app="prometheus"}')" -ge 1 ] && [ "$(lokiq '{app="app-scripts"}')" -ge 1 ] && [ "$(get status | j '$d["vector_running"]')" = true ] \
	&& pass "the apps' logs collected (Prometheus's, and the app scripts' log - root's only)" || fail "logs: $(tail -n 5 $P/_loki/vector.log)"

echo "== Grafana, with both"
install_app grafana
wait_port 3000 180 && page_up grafana
GPW=$(post password | j '$d["password"]' | tr -d '"')
[ "$(code -u admin:$GPW $G/api/user)" = 200 ] && [ "$(code -u admin:wrong $G/api/user)" = 401 ] && pass "its admin password from the page" || fail "admin: $(code -u admin:$GPW $G/api/user)"
DS=$(curl -s -u admin:$GPW $G/api/datasources | j 'implode(",", array_column($d, "uid"))' | tr -d '"')
[ "$DS" = "prometheus,loki" ] || [ "$DS" = "loki,prometheus" ] && curl -s -u admin:$GPW $G/api/datasources/uid/prometheus/health | grep -q '"status":"OK"' \
	&& curl -s -u admin:$GPW $G/api/datasources/uid/loki/health | grep -q '"status":"OK"' && pass "both data sources provisioned, and working" \
	|| fail "data sources: $DS $(curl -s -u admin:$GPW $G/api/datasources/uid/prometheus/health)"
SEARCH=$(curl -s -u admin:$GPW "$G/api/search?type=dash-db" | j 'implode(", ", array_column($d, "title"))')
echo "$SEARCH" | grep -q "WD NAS" && echo "$SEARCH" | grep -q "Node Exporter Full" && echo "$SEARCH" | grep -q -i "logs" \
	&& pass "the dashboards: $SEARCH" || fail "dashboards: $SEARCH"
# (a dashboard query, as its panels run it: the NAS's memory through the Prometheus data source)
Q=$(curl -s -u admin:$GPW -H 'Content-Type: application/json' $G/api/ds/query -d '{"queries":[{"refId":"A","datasource":{"uid":"prometheus"},"expr":"node_memory_MemTotal_bytes","instant":true}],"from":"now-5m","to":"now"}')
echo "$Q" | grep -q '"status":200' && echo "$Q" | grep -q 'node_memory_MemTotal_bytes' && pass "a panel's query through Grafana returns the NAS's metrics" || fail "query: $(echo "$Q" | head -c 300)"

echo "== Grafana's page"
NP=$(post reset_password | j '$d["password"]' | tr -d '"')
[ ${#NP} -ge 16 ] && [ "$(code -u admin:$NP $G/api/user)" = 200 ] && [ "$(code -u admin:$GPW $G/api/user)" = 401 ] && pass "a new password: it works, the old one doesn't" || fail "reset: $NP"
post backup_now > /dev/null
set -- $P/_grafana/backups/grafana-*.tar.gz
[ -f "$1" ] && [ "$(stat -c '%a' "$1")" = 600 ] && tar -tzf "$1" | grep -q "grafana.db" && pass "a backup of its database (root's only)" || fail "backup: $(ls -l $P/_grafana/backups 2>&1)"

echo "== removed"
finish_app
finish_app loki
finish_app prometheus
finish_app node_exporter
listening 3000 || listening 3100 || listening 9090 || listening 9100 && fail "something still listening" || pass "nothing left running"
