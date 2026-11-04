#!/bin/sh
# mysqld_exporter from its package (tests/common/nas.sh), on a stand-in for the NAS's MariaDB 10.5 (image.Dockerfile:
# root over the socket, no password, as WD has it), with the Prometheus app (tests/mysqld_exporter/with): its login in
# MariaDB (its status only, not your data), its own user, only on the NAS itself, no password on its command line,
# Prometheus collecting it, the dashboard's metrics there, a new login from the page, MariaDB starting after it (as at
# boot), removal
. /t/common/nas.sh mysqld_exporter
SOCK=/var/lib/mysql/mysql.sock; DATADIR=/mnt/HD_a4/.@database@
M=http://127.0.0.1:9104/metrics
metrics() { curl -s -m 10 $M; }
q() { mysql --socket=$SOCK -uroot -N -e "$1" 2>&1; }
# Waits up to $2 seconds for the exporter to say whether it reached MariaDB ($1: 1 or 0)
wait_up() { i=0; until metrics | grep -q "^mysql_up $1$" || [ $i -ge "${2:-60}" ]; do sleep 2; i=$((i + 2)); done; metrics | grep -q "^mysql_up $1$"; }
# MariaDB started as WD's startup-mysql does (mysqld_safe as root), and waited for
start_mariadb() {
    (mysqld_safe --user=root --datadir=$DATADIR --socket=$SOCK --bind-address=127.0.0.1 > /dev/null 2>&1 &)
    i=0; until q 'SELECT 1' | grep -q '^1$' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
}
prom() { curl -s -m 5 "http://127.0.0.1:9090/api/v1/$1"; }

echo "== WD's MariaDB 10.5, and Prometheus"
mkdir -p /var/lib/mysql $DATADIR
mariadb-install-db --user=root --datadir=$DATADIR --auth-root-authentication-method=normal --skip-test-db > /tmp/install-db.log 2>&1
start_mariadb
q 'SELECT VERSION()' | grep -q '^10.5' && pass "MariaDB $(q 'SELECT VERSION()') answering root on its socket" || { fail "MariaDB: $(tail -n 5 /tmp/install-db.log)"; exit 1; }
q "CREATE DATABASE family; CREATE TABLE family.recipes (name varchar(50)); INSERT INTO family.recipes VALUES ('Crème brûlée')"
install_app prometheus
wait_port 9090 60 && pass 'Prometheus answering' || { fail "Prometheus: $(tail -n 5 /tmp/start.log)"; exit 1; }

echo '== first start'
install_app
wait_port 9104 30 && pass 'answering on 9104' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
wait_up 1 30 && pass "it reached MariaDB: $(metrics | grep '^mysql_up')" || fail "mysql_up: $(metrics | grep '^mysql_up') $(tail -n 3 $D/mysqld_exporter.log)"
G=$(q "SHOW GRANTS FOR 'mysqld_exporter'@'localhost'" | tr '\n' ' ')
echo "$G" | grep -q 'GRANT PROCESS, BINLOG MONITOR ON \*\.\*\|GRANT PROCESS, REPLICATION CLIENT ON \*\.\*' && echo "$G" | grep -q 'GRANT SELECT ON `performance_schema`' \
    && ! echo "$G" | grep -q 'GRANT SELECT.* ON \*\.\*' && [ "$(q "SELECT max_user_connections FROM mysql.user WHERE user = 'mysqld_exporter'")" = 3 ] \
    && pass "its login: mysqld_exporter@localhost, MariaDB's status only, at most 3 connections" || fail "grants: $G"
mysql --socket=$SOCK -umysqld_exporter -p"$(cat $D/password)" -N -e 'SELECT name FROM family.recipes' > /tmp/denied.txt 2>&1
grep -q 'denied' /tmp/denied.txt && pass "it can't read your data: $(cut -c1-90 /tmp/denied.txt)" || fail "data readable: $(cat /tmp/denied.txt)"
PID=$(cat /var/run/mysqld_exporter.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 90 ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/credentials)" = '90 600' ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass "runs as its own user (90); its password root's, its own my.cnf its user's only" || fail "users: $(stat -c '%n %u %a' $D $D/password $D/credentials)"
awk 'NR > 1 && $4 == "0A" && index($2, ":2390") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1)'
! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$(cat $D/password)" && pass 'its password is not on its command line' || fail "cmdline: $(tr '\0' ' ' < /proc/$PID/cmdline)"

echo '== Prometheus'
i=0; until prom 'targets?scrapePool=mysql' | grep -q '"health":"up"' || [ $i -ge 90 ]; do sleep 3; i=$((i + 3)); done
prom 'targets?scrapePool=mysql' | grep -q '"health":"up"' && pass "Prometheus collects it (after ${i}s)" || fail "target: $(prom 'targets?scrapePool=mysql' | head -c 300)"
metrics > /tmp/metrics.txt
MISSING=$(php -r '$d = file_get_contents($argv[1]); preg_match_all("/\"expr\": *\"((?:[^\"\\\\]|\\\\.)*)\"/", $d, $e); preg_match_all("/\\b(mysql_[a-z_]+)\\b/", implode(" ", $e[1]), $m); $have = file_get_contents($argv[2]);
    foreach (array_unique($m[1]) as $n) { if (!preg_match("/^".$n."[{ ]/m", $have)) { echo $n, " "; } }' $P/mysqld_exporter/dashboards/mariadb.json /tmp/metrics.txt)
[ -z "$MISSING" ] && pass "every metric its dashboard uses is there ($(grep -c '^mysql_' /tmp/metrics.txt) mysql_ lines)" || fail "the dashboard uses metrics it doesn't give: $MISSING"

echo '== its page'
page_up mysqld_exporter
ST=$(get status)
[ "$(echo "$ST" | j '$d["connected"]')" = true ] && [ "$(echo "$ST" | j '$d["login"]["state"]')" = '"ok"' ] && [ "$(echo "$ST" | j '$d["prometheus"]["health"]')" = '"up"' ] \
    && [ "$(echo "$ST" | j '$d["grafana"]["installed"]')" = false ] && pass 'the page: connected, its login set up, Prometheus collecting (no Grafana)' || fail "status: $(echo "$ST" | head -c 400)"
OLD=$(cat $D/password)
R=$(post login -d confirm=1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cat $D/password)" != "$OLD" ] && wait_up 1 30 && pass 'its login set up again from the page: a new password, still connected' || fail "login again: $R"

echo '== MariaDB starting after it (as at boot), its login not yet made'
sh $P/mysqld_exporter/stop.sh $P/mysqld_exporter > /dev/null 2>&1
mysqladmin --socket=$SOCK -uroot shutdown > /dev/null 2>&1; i=0; while q 'SELECT 1' | grep -q '^1$' && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
rm -f $D/password $D/credentials $D/login.status
sh $P/mysqld_exporter/start.sh $P/mysqld_exporter > /tmp/start.log 2>&1
grep -q 'waiting for MariaDB in the background' /tmp/debug_apkg && wait_port 9104 10 && wait_up 0 20 && pass "started without MariaDB: answering, saying it's down, waiting in the background" \
    || fail "without MariaDB: $(tail -n 3 /tmp/debug_apkg) $(metrics | grep '^mysql_up')"
start_mariadb
wait_up 1 90 && [ -s $D/password ] && pass "once MariaDB answered: its login set up and it restarted, connected ($(cat $D/login.status))" || fail "after MariaDB: $(cat $D/login.status 2>&1) $(metrics | grep '^mysql_up')"

echo '== removal'
finish_app
[ ! -f $P/_prometheus/apps.d/mysqld_exporter-mysql.yml ] && ! grep -q mysqld_exporter-daily /var/spool/cron/crontabs/root \
    && pass 'its scrape job gone from Prometheus, its cron line too' || fail "left: $(ls $P/_prometheus/apps.d)"
