#!/bin/sh
# Miniflux from its package (tests/common/nas.sh), with the PostgreSQL and Nginx apps (tests/miniflux/with): its database
# and login made in PostgreSQL (owning only its database), its first start as its own user, only on the NAS itself, its
# administrator logging in with the page's password (its API, through its site), a feed subscribed to and its articles
# read, a new password from the page, backups, the network setting, started before PostgreSQL answers (as at boot), a
# restart keeping its feeds, removal
. /t/common/nas.sh miniflux
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
DOMAIN=nas.example.test
PGBIN=$P/postgresql/binaries/postgresql/bin
M=http://127.0.0.1:8099
site() { p=$1; shift; curl -sk -m 15 --resolve "miniflux.$DOMAIN:443:127.0.0.1" "$@" "https://miniflux.$DOMAIN$p"; }
# Its API as admin (with a password - default: the app's): api <path> [curl options]
api() { p=$1; shift; curl -s -m 30 -u "admin:${PW:-$(cat $D/password)}" "$@" "$M/v1$p"; }
q() { PGPASSWORD="$PGPW" $PGBIN/psql -h /var/run/postgresql -U postgres -d "${2:-miniflux}" -X -tA -c "$1" 2>&1; }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1FA3") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with PostgreSQL and Nginx'
install_app postgresql
wait_port 5432 60 && pass 'PostgreSQL answering' || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
page_up postgresql; PGPW=$(post password | j '$d["password"]' | tr -d '"'); D=$P/_miniflux
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
# A feed to subscribe to, on the NAS itself
mkdir -p /tmp/feed && cat > /tmp/feed/feed.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>Test Kitchen</title><link>http://127.0.0.1:8765/</link><description>Recipes</description>
<item><title>Soup of the day</title><link>http://127.0.0.1:8765/soup</link><guid>soup-1</guid><description>Leek and potato</description></item>
<item><title>Bread</title><link>http://127.0.0.1:8765/bread</link><guid>bread-1</guid><description>Sourdough</description></item>
</channel></rss>
EOF
(php -S 127.0.0.1:8765 -t /tmp/feed > /tmp/feed.log 2>&1 &)

echo '== first start'
install_app
wait_port 8099 60 && [ "$(curl -s $M/healthcheck)" = OK ] && pass "answering on 8099: Miniflux $($P/miniflux/binaries/miniflux -version)" \
    || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/miniflux.log)"; exit 1; }
PID=$(cat /var/run/miniflux.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 63 ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/db_password)" = '0 600' ] \
    && [ "$(stat -c '%U %G %a' $D/conf/miniflux.conf)" = 'root miniflux 640' ] && ! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$(cat $D/db_password)" \
    && pass 'runs as its own user (63), its passwords root'"'"'s (its configuration readable by its group, no password on its command line)' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/conf)"
[ "$(q "SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = 'miniflux'" postgres)" = f ] \
    && [ "$(q "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'miniflux'" postgres)" = miniflux ] && [ "$(q 'SELECT count(*) FROM users')" = 1 ] \
    && pass "its database in PostgreSQL: miniflux, owned by its own login (nothing more), its administrator made" || fail "database: $(q 'SELECT username FROM users')"
! listens_beyond && pass 'only on the NAS itself (127.0.0.1:8099) - with the Nginx app installed' || fail 'listens beyond the NAS'

echo '== logins and feeds'
[ "$(api /me | j '$d["username"]')" = '"admin"' ] && pass "its administrator (admin) logs in with the page's password" || fail "admin: $(api /me)"
[ "$(PW=wrong-password api /me -o /dev/null -w '%{http_code}')" = 401 ] && pass 'a wrong password refused' || fail 'wrong password'
R=$(api /feeds -H 'Content-Type: application/json' -d '{"feed_url": "http://127.0.0.1:8765/feed.xml", "category_id": 1}')
echo "$R" | grep -q 'refusing to access private network' && pass 'feeds on the local network refused by default' || fail "private feed: $R"
page_up miniflux
R=$(post listen -d listen=local -d private_feeds=on); wait_port 8099 30
grep -q '^FETCHER_ALLOW_PRIVATE_NETWORKS=1$' $D/conf/miniflux.conf && [ "$(echo "$R" | j '$d["ok"]')" = true ] \
    && pass 'and allowed from the page' || fail "private feeds: $R"
R=$(api /feeds -H 'Content-Type: application/json' -d '{"feed_url": "http://127.0.0.1:8765/feed.xml", "category_id": 1}')
FEED=$(echo "$R" | j '$d["feed_id"] ?? 0')
i=0; while [ $i -lt 15 ] && [ "$(api "/feeds/$FEED/entries" | j '$d["total"] ?? 0')" != 2 ]; do sleep 2; i=$((i + 1)); done
E=$(api "/feeds/$FEED/entries")
[ "$FEED" != 0 ] && [ "$(echo "$E" | j '$d["total"]')" = 2 ] && echo "$E" | grep -q 'Soup of the day' \
    && pass "a feed subscribed to, its articles fetched: $(echo "$E" | j 'implode(", ", array_column($d["entries"], "title"))')" || fail "feed: $R / $(echo "$E" | head -c 300)"

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:8099' $P/_nginx/sites/60-app-miniflux.conf 2>/dev/null && site / | grep -q 'name="username"' \
    && [ "$(site /v1/me -u "admin:$(cat $D/password)" | j '$d["username"]')" = '"admin"' ] && grep -q "^BASE_URL=https://miniflux.$DOMAIN/$" $D/conf/miniflux.conf \
    && pass "its site https://miniflux.$DOMAIN/ (its login page, and its API), its own address set to it" \
    || fail "site: $(ls $P/_nginx/sites; grep BASE_URL $D/conf/miniflux.conf; site / | head -c 300; site /v1/me -u "admin:$(cat $D/password)")"

echo '== its page'
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"2.3.5"' ] && [ "$(echo "$ST" | j '$d["db"]["state"]')" = '"ok"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://miniflux.$DOMAIN/\"" ] && pass 'status: running, 2.3.5, its database, its site' || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the page shows the password' || fail 'password not shown'
OLD=$(cat $D/password); R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(PW=Brand.New-Password_1 api /me | j '$d["username"]')" = '"admin"' ] \
    && [ "$(PW=$OLD api /me -o /dev/null -w '%{http_code}')" = 401 ] && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"

echo '== backups'
R=$(post backup_now -d confirm=1); F=$(ls $D/backups/miniflux-*.dump 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] && $PGBIN/pg_restore -l "$F" | grep -q 'TABLE DATA public entries' \
    && pass "a backup of its database from the page (pg_dump, root's only): $(basename "$F")" || fail "backup: $R"

echo '== on the network'
R=$(post listen -d listen=all -d private_feeds=on)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q '^LISTEN_ADDR=0.0.0.0:8099$' $D/conf/miniflux.conf \
    && pass 'on the network too (0.0.0.0:8099)' || fail "listen all: $R"
post listen -d listen=local -d private_feeds=on > /dev/null
! listens_beyond && pass 'and back to the NAS only' || fail 'listen local'

echo '== started before PostgreSQL (as at boot)'
sh $P/miniflux/stop.sh $P/miniflux > /dev/null 2>&1
sh $P/postgresql/stop.sh $P/postgresql > /dev/null 2>&1
listening 8099 && fail 'still answering once stopped' || pass 'stopped'
# As at boot with nothing kept: its database login made again once PostgreSQL answers
mv $D/db_password $D/db_password.old
sh $P/miniflux/start.sh $P/miniflux > /tmp/start.log 2>&1
sleep 3
listening 8099 && fail 'started without PostgreSQL' || pass 'not started while PostgreSQL is down (waiting in the background)'
sh $P/postgresql/start.sh $P/postgresql > /dev/null 2>&1
i=0; until [ "$(curl -s $M/healthcheck)" = OK ] || [ $i -ge 120 ]; do sleep 3; i=$((i + 3)); done
[ "$(curl -s $M/healthcheck)" = OK ] && ! cmp -s $D/db_password $D/db_password.old && [ "$(PW=Brand.New-Password_1 api "/feeds/$FEED/entries" | j '$d["total"]')" = 2 ] \
    && pass "started once PostgreSQL answered (after ${i}s, a new database password), its feeds and administrator kept" || fail "later: $(tail -n 5 /tmp/debug_apkg)"

echo '== removal'
finish_app
! grep -q miniflux- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-miniflux.conf ] && [ "$(q 'SELECT count(*) FROM feeds')" = 1 ] \
    && pass 'its cron lines and site gone, its database kept in PostgreSQL' || fail 'left behind'
finish_app nginx
