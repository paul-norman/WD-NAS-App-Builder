#!/bin/sh
# The MariaDB app from its package (tests/common/nas.sh), on a stand-in for WD's own MariaDB 10.5 (wd.sh): 11.8 swapped
# in underneath WD's startup-mysql (WD's scripts still find and restart it), on an upgraded copy of WD's data (WD's own
# left as it was), WD's lock left free, the page, switching back (my.cnf exactly as before) and again, starting afresh
# ("fresh"), removal
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
