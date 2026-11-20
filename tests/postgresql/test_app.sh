#!/bin/sh
# PostgreSQL from its package (tests/common/nas.sh): its first start as its own user (no su on the NAS - pg_runas),
# passwords only (scram-sha-256), databases with users of their own from the page, the bundled extensions (PostGIS with
# PROJ's data, pgvector, pg_cron once preloaded), the postgres password, the network switch, the upgrade of the previous
# major version's data (made with its bundled server, as its app made it) and of data it can't upgrade, removal
. /t/common/nas.sh postgresql
# A password with what used to be refused: spaces, quotes, a backslash, ^ & and an accented letter
XPW='Tëst ^&"'"'"'\ pass 1'
# A field of the JSON on the input, decoded (password by default)
jpw() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo isset($d[$argv[1]]) ? $d[$argv[1]] : "";' "${1:-password}"; }
PSQL=$P/postgresql/binaries/postgresql/bin/psql
# A query over TCP (as an app connects): sql <user> <password> <database> <sql> [host]
sql() { PGPASSWORD="$2" PGCONNECT_TIMEOUT=5 $PSQL -h "${5:-127.0.0.1}" -U "$1" -d "$3" -tAq -v ON_ERROR_STOP=1 -c "$4" 2>&1; }

echo '== first start'
install_app
wait_port 5432 60 && pass 'answering on 5432' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg)"; exit 1; }
page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"19.0"' ] && [ "$(echo "$ST" | j '$d["network"]')" = false ] && echo "$ST" | grep -q '"name":"postgres"' \
    && pass 'the page: PostgreSQL 19.0, its databases, only on the NAS itself' || fail "status: $(echo "$ST" | head -c 300)"
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
R=$(post create_database -d name=notes --data-urlencode "password=$XPW")
[ "$(echo "$R" | jpw)" = "$XPW" ] && [ "$(sql notes "$XPW" notes 'SELECT 1')" = 1 ] \
    && pass 'one with a typed password (spaces, quotes, a backslash: quoted for the SQL) logs in with it' || fail "typed password: $R"
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
NP=$(post set_password --data-urlencode "password=$XPW" | jpw)
[ "$NP" = "$XPW" ] && [ "$(sql postgres "$NP" postgres 'SELECT 1')" = 1 ] && sql postgres "$PW" postgres 'SELECT 1' | grep -q 'failed' \
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

echo "== an upgrade from PostgreSQL 18's data"
# The previous app's data, made with the bundled PostgreSQL 18 as that app made it (initdb's options, its settings
# block), then used: the network on, pg_cron and pgaudit preloaded, an ALTER SYSTEM setting, a database with its own user,
# PostGIS (with statistics), a pg_cron job, pgaudit
BIN=$P/postgresql/binaries/postgresql/bin
OLD=$P/postgresql/binaries/postgresql/previous/bin
RUNAS="$BIN/pg_runas 70 70"
NP=$(cat $D/postgres_password)
osql() { PGPASSWORD="$NP" $PSQL -h /var/run/postgresql -U postgres -d "$1" -tAq -v ON_ERROR_STOP=1 -c "$2" 2>&1; }
sh $P/postgresql/pgsql_ctl.sh stop > /dev/null
rm -rf $D/data
mkdir -m 700 $D/data && chown 70:70 $D/data && cp $D/postgres_password /tmp/pw && chown 70 /tmp/pw
$RUNAS $OLD/initdb -D $D/data -U postgres --pwfile=/tmp/pw --encoding=UTF8 --locale-provider=builtin --builtin-locale=C.UTF-8 \
    --auth=scram-sha-256 > /tmp/initdb18.log 2>&1 || fail "initdb 18: $(tail -n 5 /tmp/initdb18.log)"
printf "\n# --- added by the postgresql app ---\nlisten_addresses = '*'\nunix_socket_directories = '/var/run/postgresql'\nshared_preload_libraries = 'pg_cron,pgaudit'\ncron.database_name = 'postgres'\n# --- end of the postgresql app's settings ---\n" >> $D/data/postgresql.conf
printf "# --- added by the postgresql app ---\nhost    all             all             samenet                 scram-sha-256\n# --- end of the postgresql app's settings ---\n" >> $D/data/pg_hba.conf
$RUNAS $OLD/pg_ctl start -D $D/data -w -t 60 -l /tmp/pg18.log > /dev/null 2>&1
osql postgres 'SELECT version()' | grep -q 'PostgreSQL 18\.' && pass "PostgreSQL 18 ran on its data (the bundled previous version)" || fail "18: $(tail -n 5 /tmp/pg18.log)"
# (one statement each where a transaction block isn't allowed: ALTER SYSTEM, CREATE DATABASE)
R=$(osql postgres "ALTER SYSTEM SET work_mem = '12MB'"; osql postgres "CREATE ROLE maps LOGIN PASSWORD 'maps-password-1'"
    osql postgres 'CREATE DATABASE maps OWNER maps'; osql postgres "CREATE EXTENSION pg_cron; SELECT cron.schedule('nightly', '0 3 * * *', 'VACUUM')"
    osql maps "CREATE EXTENSION postgis; CREATE EXTENSION pgaudit; CREATE TABLE places (name text, p geometry(Point, 4326)); INSERT INTO places SELECT 'p' || i, ST_MakePoint(i % 180, i % 90) FROM generate_series(1, 500) i; ALTER TABLE places OWNER TO maps; ANALYZE places")
[ "$(osql maps "SELECT extversion FROM pg_extension WHERE extname = 'pgaudit'")" = 18.0 ] && [ "$(osql maps 'SELECT count(*) FROM places')" = 500 ] \
    && pass "...used: a database of its user's with PostGIS data, pgaudit 18.0, a pg_cron job, ALTER SYSTEM's setting" || fail "using 18: $R"
$RUNAS $OLD/pg_ctl stop -D $D/data -m fast -w > /dev/null 2>&1
sh $P/postgresql/pgsql_ctl.sh start > /tmp/upgrade.log 2>&1
wait_port 5432 120
[ "$(cat $D/data/PG_VERSION)" = 19 ] && [ "$(cat $D/data-18/PG_VERSION)" = 18 ] && [ "$(stat -c '%u %a' $D/data)" = '70 700' ] && [ ! -e $D/upgrade ] && [ ! -e $D/problem ] \
    && pass 'its data upgraded to PostgreSQL 19 (a copy; the old one kept as data-18, as it was)' || fail "upgrade: $(cat /tmp/upgrade.log; grep -i upgrad /tmp/debug_apkg | tail -n 5)"
[ "$(sql maps maps-password-1 maps "SELECT count(*), round(max(ST_X(p))) FROM places" "$IP")" = '500|179' ] \
    && pass "its user logs in with its password over the network (its settings kept), its PostGIS data there" || fail "maps: $(sql maps maps-password-1 maps 'SELECT 1' "$IP")"
# (the statistics pg_upgrade couldn't carry over are made in the background after it)
i=0; while [ $i -lt 30 ] && [ "$(osql maps "SELECT count(*) FROM pg_stats WHERE tablename = 'places'")" != 2 ]; do sleep 1; i=$((i + 1)); done
[ "$(osql maps "SELECT count(*) FROM pg_stats WHERE tablename = 'places'")" = 2 ] && [ "$(osql postgres 'SHOW work_mem')" = 12MB ] \
    && [ "$(osql postgres 'SELECT jobname FROM cron.job')" = nightly ] && [ "$(get status | j '$d["preload"]')" = '["pg_cron","pgaudit"]' ] \
    && pass "the planner's statistics (PostGIS's too), ALTER SYSTEM's setting, the pg_cron job and the preloaded extensions carried over" \
    || fail "carried: $(osql maps "SELECT count(*) FROM pg_stats WHERE tablename = 'places'") $(osql postgres 'SHOW work_mem') $(osql postgres 'SELECT jobname FROM cron.job')"
[ "$(osql maps "SELECT extversion FROM pg_extension WHERE extname = 'pgaudit'")" = 19.0 ] \
    && pass "pgaudit updated to its PostgreSQL 19 version (pg_upgrade's update_extensions.sql)" || fail "pgaudit: $(osql maps "SELECT extversion FROM pg_extension WHERE extname = 'pgaudit'")"
ST=$(get status)
[ "$(echo "$ST" | j '$d["old_data"][0]["name"]')" = '"data-18"' ] && [ "$(echo "$ST" | j '$d["problem"]')" = '""' ] && [ "$(echo "$ST" | j '$d["version"]')" = '"19.0"' ] \
    && pass 'the page: PostgreSQL 19.0 running, data-18 kept' || fail "status: $(echo "$ST" | head -c 400)"
post remove_old_data -d name=data | grep -q 'Not data kept' && post remove_old_data -d name=../_postgresql | grep -q 'Not data kept' && [ -d $D/data ] \
    && pass "the page removes nothing but the old data" || fail 'remove checks'
R=$(post remove_old_data -d name=data-18)
[ "$(echo "$R" | j '$d["removed"]')" = '"data-18"' ] && [ ! -e $D/data-18 ] && [ "$(get status | j '$d["old_data"]')" = '[]' ] \
    && pass '...removed from the page once no longer needed' || fail "remove: $R"

echo "== data it can't upgrade"
sh $P/postgresql/pgsql_ctl.sh stop > /dev/null
mv $D/data /tmp/data19
mkdir -m 700 $D/data && echo 17 > $D/data/PG_VERSION && chown -R 70:70 $D/data
sh $P/postgresql/pgsql_ctl.sh start > /dev/null 2>&1
sleep 2
! listening 5432 && [ "$(cat $D/data/PG_VERSION)" = 17 ] && [ ! -e $D/data.new ] && get status | j '$d["problem"]' | grep -q "PostgreSQL 17's" \
    && pass "PostgreSQL 17's data: refused, untouched, the reason on the page" || fail "17: $(get status | head -c 300)"
rm -rf $D/data && mv /tmp/data19 $D/data
sh $P/postgresql/pgsql_ctl.sh start > /dev/null 2>&1; wait_port 5432 60
[ ! -e $D/problem ] && [ "$(osql postgres 'SELECT 1')" = 1 ] && pass '...and running again on its own data' || fail 'restart after 17'

echo '== removed'
finish_app
