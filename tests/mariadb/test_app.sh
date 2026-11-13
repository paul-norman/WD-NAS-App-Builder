#!/bin/sh
# The MariaDB app from its package (tests/common/nas.sh), on a stand-in for WD's own MariaDB 10.5 (wd.sh): 11.8 swapped
# in underneath WD's startup-mysql (WD's scripts still find and restart it), on an upgraded copy of WD's data (WD's own
# left as it was), WD's lock left free, the page, switching back (my.cnf exactly as before) and again, starting afresh
# ("fresh"), removal - then, on a NAS without a MariaDB of its own, MariaDB run by the app itself
. /t/common/nas.sh mariadb
# The NAS's ps takes "ps -aux", as WD's mysql_reset.py and the app use it to find the data folder - the test BusyBox's
# doesn't
rm -f /tmp/bb/ps
sh /t/app/wd.sh
WD_DATA=/mnt/HD_a4/.@database@; SOCK=/var/lib/mysql/mysql.sock
cp /etc/my.cnf /tmp/my.cnf.before
# A query as root, with 11.8's client while the app is installed (WD's 10.5 one warns about 11.8's character sets)
q() { c=mysql; [ -x $P/mariadb/binaries/mariadb/bin/mariadb ] && [ "$(readlink /usr/libexec/mariadbd)" != /usr/local/modules/mysql/libexec/mariadbd ] && c=$P/mariadb/binaries/mariadb/bin/mariadb
    $c --socket=$SOCK -uroot -N -e "$1" 2>&1; }
# Waits for the server to answer as the version given
wait_version() { i=0; until q 'SELECT VERSION()' | grep -q "^$1" || [ $i -ge ${2:-90} ]; do sleep 1; i=$((i + 1)); done; q 'SELECT VERSION()' | grep -q "^$1"; }

echo "== WD's MariaDB 10.5 (before)"
wait_version 10.5 && [ "$(q 'SELECT name FROM family.recipes')" = "Crème brûlée" ] && pass "the stand-in NAS runs WD's MariaDB $(q 'SELECT VERSION()'), with the user's data" \
    || { fail "stand-in: $(q 'SELECT VERSION()') $(tail -n 5 /tmp/wd-install-db.log)"; exit 1; }

echo '== switched to 11.8'
install_app
wait_version 11.8 && pass "MariaDB $(q 'SELECT VERSION()') is the NAS's MariaDB" || fail "not swapped: $(q 'SELECT VERSION()') $(tail -n 8 /tmp/debug_apkg)"
ps -aux | grep -q "/usr/libexec/mariadbd .*--datadir=$WD_DATA" && [ "$(cat $D/wd_datadir)" = "$WD_DATA" ] && grep -q " $WD_DATA " /proc/mounts \
    && pass "run by WD's startup-mysql, as /usr/libexec/mariadbd on WD's data folder (as WD's scripts look for it) - a copy mounted over it" || fail "how it runs: $(ps -aux | grep mariadbd | head -n 2)"
[ "$(q 'SELECT name FROM family.recipes')" = "Crème brûlée" ] && grep -q '^11.8.9' $D/data/mysql_upgrade_info && [ "$(q "SELECT COUNT(*) FROM mysql.global_priv WHERE User = 'root'")" -ge 1 ] \
    && pass "the user's data carried over (accents intact), upgraded once (recorded where WD's mysql_reset.py looks)" || fail "data: $(q 'SELECT name FROM family.recipes') $(cat $D/data/mysql_upgrade_info)"
flock -n /run/lock/mysql_reset.py.lock true && pass "WD's MariaDB lock left free (WD's mysql_reset.py isn't blocked)" || fail 'the lock is still held'
READ_ONLY_PAGE=1 page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["app_server"]')" = true ] && echo "$ST" | j '$d["version"]' | grep -q '"11.8.9' && [ "$(echo "$ST" | j 'count(array_filter($d["problems"], function ($l) { return strpos($l, "[ERROR]") !== false; }))')" = 0 ] \
    && pass 'the page: 11.8 running, no errors since it started' || fail "page: $(echo "$ST" | head -c 400)"
q "INSERT INTO family.recipes VALUES ('Tarte Tatin'); CREATE TABLE family.t (j json, d datetime(6))" > /dev/null

echo "== restarted as WD's scripts do"
killall mysqld mysqld_safe mariadbd mariadbd-safe 2>/dev/null; i=0; while pidof mariadbd > /dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
(startup-mysql > /dev/null 2>&1 &); wait_version 11.8 && [ "$(q 'SELECT COUNT(*) FROM family.recipes')" = 2 ] && pass 'killall + startup-mysql (as mysql_reset.py restarts it): still 11.8, the data kept' || fail "WD restart: $(q 'SELECT VERSION()')"

echo '== switched back (stopped), and again'
sh $P/mariadb/stop.sh $P/mariadb > /dev/null 2>&1
wait_version 10.5 && [ "$(q 'SELECT name FROM family.recipes')" = "Crème brûlée" ] && cmp -s /etc/my.cnf /tmp/my.cnf.before && [ ! -e /usr/local/mysql ] && ! grep -q " $WD_DATA " /proc/mounts \
    && pass "back to WD's 10.5 on WD's own data, untouched (without 11.8's row); my.cnf byte for byte as before" || fail "restore: $(q 'SELECT VERSION()') $(diff /tmp/my.cnf.before /etc/my.cnf)"
sh $P/mariadb/start.sh $P/mariadb > /dev/null 2>&1
wait_version 11.8 && [ "$(q 'SELECT COUNT(*) FROM family.recipes')" = 2 ] && [ "$(grep -c "added by the mariadb app" /etc/my.cnf)" = 1 ] \
    && pass '11.8 again, on its copy (its own rows still there, not copied again)' || fail "re-enable: $(q 'SELECT VERSION()')"

echo '== starting afresh'
sh $P/mariadb/mariadb_swap.sh fresh > /tmp/fresh.log 2>&1
wait_version 11.8 && q 'SHOW DATABASES' | grep -qv family && ! q 'SHOW DATABASES' | grep -q family && [ -n "$(ls -d $D/data.old-* 2>/dev/null)" ] && [ "$(q 'SELECT 1')" = 1 ] \
    && pass "fresh: new system tables (root without a password, as WD's scripts expect); the old copy kept ($(basename $(ls -d $D/data.old-*)))" || fail "fresh: $(tail -n 5 /tmp/fresh.log)"

echo '== removed'
finish_app
wait_version 10.5 && [ "$(q 'SELECT name FROM family.recipes')" = "Crème brûlée" ] && cmp -s /etc/my.cnf /tmp/my.cnf.before && pass "WD's MariaDB 10.5 back, with WD's data" || fail "after removal: $(q 'SELECT VERSION()')"

echo "== WD's data with an inconsistent catalogue"
# A database and an account of the user's own in WD's 10.5 - then four of its system tables' files lost, as on NASes
# whose data started life on an older MySQL (InnoDB still lists them), and its upgrade record too: 11.8's upgrade then
# fails (as on an EX2 Ultra: "Table ... already exists"), and the rebuild has to take over from there
q "CREATE DATABASE shop; CREATE TABLE shop.items (name varchar(50)) DEFAULT CHARSET utf8mb4; INSERT INTO shop.items VALUES ('Café'); CREATE USER 'shopper'@'localhost' IDENTIFIED BY 'Shop-pass-1'; GRANT ALL ON shop.* TO 'shopper'@'localhost'" > /dev/null
killall mysqld mysqld_safe mariadbd mariadbd-safe 2>/dev/null; i=0; while pidof mariadbd > /dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
rm -f $WD_DATA/mysql/innodb_table_stats.ibd $WD_DATA/mysql/innodb_index_stats.ibd $WD_DATA/mysql/transaction_registry.ibd \
    $WD_DATA/mysql/gtid_slave_pos.ibd $WD_DATA/mysql_upgrade_info
(startup-mysql > /dev/null 2>&1 &); wait_version 10.5
rm -rf $D
install_app
wait_version 11.8 180
[ -n "$(q 'SELECT COUNT(*) FROM mysql.innodb_table_stats' | grep '^[0-9]*$')" ] && [ -n "$(q 'SELECT COUNT(*) FROM mysql.transaction_registry' | grep '^[0-9]*$')" ] \
    && pass "its system tables rebuilt by itself: usable again" || fail "system tables: $(q 'SELECT COUNT(*) FROM mysql.innodb_table_stats') $(grep mariadb /tmp/debug_apkg | tail -n 6)"
grep -q 'Upgrading the data failed' /tmp/debug_apkg && grep -q 'Rebuilt the system tables' /tmp/debug_apkg \
    && pass "after 11.8's upgrade failed on it (as on the EX2 Ultra)" || fail "upgrade: $(grep -c 'already exists' /tmp/debug_apkg) $(grep mariadb /tmp/debug_apkg | tail -n 4)"
[ "$(q 'SELECT name FROM shop.items')" = 'Café' ] && [ "$($P/mariadb/binaries/mariadb/bin/mariadb --socket=$SOCK -ushopper -pShop-pass-1 -N -e 'SELECT COUNT(*) FROM shop.items' 2>&1)" = 1 ] \
    && pass "the user's database (accents intact) and account (its password and grants) carried over" || fail "carried over: $(q 'SELECT name FROM shop.items') $(grep mariadb /tmp/debug_apkg | tail -n 4)"
[ -f $D/rebuilt ] && [ -n "$(ls -d $D/data.old-* 2>/dev/null)" ] && [ ! -e $D/rebuild.sql ] \
    && pass "the copy as it was kept ($(basename $(ls -d $D/data.old-*))), the dump of its users gone" || fail "kept: $(ls -la $D)"
READ_ONLY_PAGE=1 page_up
get status | j '$d["rebuilt"]' | grep -q 'data.old-' && pass 'the page says so' || fail "page: $(get status | head -c 300)"
finish_app
wait_version 10.5 && pass "WD's MariaDB 10.5 back, its own data as it was" || fail "after removal: $(q 'SELECT VERSION()')"

echo "== a NAS without a MariaDB of its own"
# WD's MariaDB taken away (its server, startup-mysql and client - as perhaps on some ARM models), and the app's earlier
# data, so that it starts as on such a NAS
killall mysqld mysqld_safe mariadbd mariadbd-safe 2>/dev/null; i=0; while pidof mariadbd > /dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
rm -f /usr/bin/startup-mysql /usr/local/modules/mysql/libexec/mariadbd /usr/libexec/mariadbd /etc/my.cnf
for c in mysql mariadb; do [ -e /usr/bin/$c ] && mv /usr/bin/$c /usr/bin/$c.wd; done
rm -rf $D
install_app
own() { $P/mariadb/binaries/mariadb/bin/mariadb --socket=$SOCK -uroot -N -e "$1" 2>&1; }
i=0; until own 'SELECT VERSION()' | grep -q '^11.8' || [ $i -ge 90 ]; do sleep 1; i=$((i + 1)); done
own 'SELECT VERSION()' | grep -q '^11.8.9' && [ "$(cat $D/mode)" = own ] && [ -f $D/data/mysql_upgrade_info ] \
    && ps -aux | grep -q "/usr/libexec/mariadbd .*--datadir=$D/data" \
    && pass "MariaDB $(own 'SELECT VERSION()') runs by itself, on new data of its own, as /usr/libexec/mariadbd" \
    || fail "own mode: $(own 'SELECT VERSION()') $(cat $D/mode 2>/dev/null) $(tail -n 8 /tmp/debug_apkg)"
own "CREATE DATABASE family; CREATE TABLE family.recipes (name varchar(50)) DEFAULT CHARSET utf8mb4; INSERT INTO family.recipes VALUES ('Pain perdu')" > /dev/null
awk 'NR > 1 && $4 == "0A" && index($2, ":0CEA") { print $2 }' /proc/net/tcp | grep -q '^0100007F:0CEA$' \
    && [ "$(own 'SELECT name FROM family.recipes')" = 'Pain perdu' ] \
    && pass 'where WD'"'"'s would be: the socket, 127.0.0.1:3306 only, root without a password' || fail "listening: $(cat /proc/net/tcp | head -n 5)"
READ_ONLY_PAGE=1 page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["mode"]')" = '"own"' ] && [ "$(echo "$ST" | j '$d["app_server"]')" = true ] && echo "$ST" | j '$d["version"]' | grep -q '"11.8.9' \
    && pass 'the page: running by itself' || fail "page: $(echo "$ST" | head -c 300)"
sh $P/mariadb/stop.sh $P/mariadb > /dev/null 2>&1
! pidof mariadbd > /dev/null && [ ! -e /usr/libexec/mariadbd ] && [ ! -e /usr/local/mysql ] && pass 'disabled: stopped, its links gone' || fail "stop: $(ps -aux | grep mariadbd | head -n 2)"
sh $P/mariadb/start.sh $P/mariadb > /dev/null 2>&1
i=0; until own 'SELECT 1' | grep -q '^1$' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
[ "$(own 'SELECT name FROM family.recipes')" = 'Pain perdu' ] && pass 'enabled again (as at boot): its data kept' || fail "restart: $(own 'SELECT VERSION()')"
finish_app
! pidof mariadbd > /dev/null && [ -d $D/data/family ] && pass 'removed: stopped, its data kept' || fail 'removal (own)'
