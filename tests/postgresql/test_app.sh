#!/bin/sh
# PostgreSQL from its package (tests/common/nas.sh): its first start as its own user (no su on the NAS - pg_runas),
# passwords only (scram-sha-256), databases with users of their own from the page, the bundled extensions (PostGIS with
# PROJ's data, pgvector, pg_cron once preloaded), the postgres password, the network switch, removal
. /t/common/nas.sh postgresql
PSQL=$P/postgresql/binaries/postgresql/bin/psql
# A query over TCP (as an app connects): sql <user> <password> <database> <sql> [host]
sql() { PGPASSWORD="$2" PGCONNECT_TIMEOUT=5 $PSQL -h "${5:-127.0.0.1}" -U "$1" -d "$3" -tAq -v ON_ERROR_STOP=1 -c "$4" 2>&1; }

echo '== first start'
install_app
wait_port 5432 60 && pass 'answering on 5432' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"18.6"' ] && [ "$(echo "$ST" | j '$d["network"]')" = false ] && echo "$ST" | grep -q '"name":"postgres"' \
    && pass 'the page: PostgreSQL 18.6, its databases, only on the NAS itself' || fail "status: $(echo "$ST" | head -c 300)"
PID=$(head -n 1 $D/data/postmaster.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 70 ] && [ "$(stat -c '%u %a' $D/data)" = '70 700' ] && [ "$(stat -c '%u %a' $D/postgres_password)" = '0 600' ] \
    && pass "runs as its own user (70, through pg_runas); its data its own, the postgres password root's" || fail "users: $(stat -c '%n %u %a' $D/data $D/postgres_password)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1538") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv "^0100007F:\|^00000000000000000000000001000000:" \
    && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself'

echo '== passwords'
PW=$(post password | j '$d["password"]' | tr -d '"')
[ "$(sql postgres "$PW" postgres 'SELECT 1')" = 1 ] && sql postgres wrong postgres 'SELECT 1' | grep -q 'password authentication failed' \
    && sql postgres '' postgres 'SELECT 1' | grep -q 'password' && pass 'the postgres password from the page; a wrong or no password refused (scram-sha-256)' \
    || fail "auth: $(sql postgres "$PW" postgres 'SELECT 1')"

echo '== a database with its own user'
R=$(post create_database -d name=photos)
UPW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ "$(echo "$R" | j '$d["user"]')" = '"photos"' ] && [ "$(sql photos "$UPW" photos 'CREATE TABLE t (id int); INSERT INTO t VALUES (7); SELECT id FROM t')" = 7 ] \
    && pass 'created from the page: its user owns it (creates tables)' || fail "create: $R"
post create_database -d 'name=bad name' | grep -q 'Names are' && post create_database -d name=pg_x | grep -q 'Names are' \
    && post create_database -d name=photos | grep -q 'refused' && pass 'bad and existing names refused' || fail 'name checks'

echo '== extensions'
R=$(sql postgres "$PW" photos "CREATE EXTENSION postgis; SELECT ST_AsText(ST_SnapToGrid(ST_Transform(ST_SetSRID(ST_MakePoint(-0.1276, 51.5072), 4326), 27700), 1))")
echo "$R" | grep -q '^POINT(530' && pass "PostGIS with PROJ's data: London in British National Grid: $R" || fail "postgis: $R"
R=$(sql postgres "$PW" photos "CREATE EXTENSION vector; SELECT '[1,2,3]'::vector <-> '[4,6,3]'::vector")
[ "$R" = 5 ] && pass "pgvector: a distance of $R" || fail "pgvector: $R"
sql postgres "$PW" postgres 'CREATE EXTENSION pg_cron' | grep -q 'cron' && pass 'pg_cron needs preloading (refused before)' || fail 'pg_cron created without preloading'
post preload -d 'extensions[]=pg_cron' > /dev/null; wait_port 5432 30; sleep 1
R=$(sql postgres "$PW" postgres "CREATE EXTENSION pg_cron; SELECT cron.schedule('nightly', '0 3 * * *', 'VACUUM')")
[ "$R" -ge 1 ] 2>/dev/null && [ "$(get status | j '$d["preload"]')" = '["pg_cron"]' ] && pass 'preloaded from the page: a pg_cron job scheduled' || fail "pg_cron: $R"

echo '== a new postgres password'
NP=$(post set_password | j '$d["password"]' | tr -d '"')
[ "$NP" != "$PW" ] && [ "$(sql postgres "$NP" postgres 'SELECT 1')" = 1 ] && sql postgres "$PW" postgres 'SELECT 1' | grep -q 'failed' \
    && [ "$(cat $D/postgres_password)" = "$NP" ] && pass "it works, the old one doesn't" || fail "set_password: $NP"

echo '== the network switch'
IP=$(ip -4 addr show eth0 | awk '/inet / { split($2, a, "/"); print a[1] }')
sql photos "$UPW" photos 'SELECT 1' "$IP" | grep -q "refused\|could not connect" && pass "off: not reachable on the network ($IP)" || fail "reachable: $(sql photos "$UPW" photos 'SELECT 1' "$IP")"
post network -d on=1 > /dev/null; wait_port 5432 30; sleep 1
[ "$(sql photos "$UPW" photos 'SELECT id FROM t' "$IP")" = 7 ] && [ "$(get status | j '$d["network"]')" = true ] && grep -qE '^host +all +all +samenet +scram-sha-256' $D/data/pg_hba.conf \
    && pass "on: the local network's computers connect (with passwords)" || fail "network on: $(sql photos "$UPW" photos 'SELECT 1' "$IP")"
post network > /dev/null; wait_port 5432 30; sleep 1
sql photos "$UPW" photos 'SELECT 1' "$IP" | grep -q "refused\|could not connect" && [ "$(sql photos "$UPW" photos 'SELECT id FROM t')" = 7 ] \
    && pass '...and off again (the data kept)' || fail 'network off'

echo '== removed'
finish_app
