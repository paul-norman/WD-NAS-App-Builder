#!/bin/sh
# Compass Web from its package (tests/common/nas.sh), with the MongoDB and Nginx apps (tests/compass-web/with): not
# started without MongoDB set up, its own user, only on the NAS itself, nothing without its login (its health check
# aside), its web interface, its connection to MongoDB as the MongoDB app's administrator (documents read through it),
# its site through Nginx, a new password from the page, following MongoDB's new password, the network setting, removal
. /t/common/nas.sh compass-web
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
MBIN=$P/mongodb/binaries/bin
cw() { p=$1; shift; curl -s -m 20 "$@" "http://127.0.0.1:8087$p"; }
site() { p=$1; shift; curl -sk -m 20 --resolve "compass.$DOMAIN:443:127.0.0.1" "$@" "https://compass.$DOMAIN$p"; }
# Documents counted through Compass Web's own connection to MongoDB (its first connection): fields <password> [site]
fields() {
    ID=$(${2:-cw} /api/connection-info -u "admin:$1" | php -r '$c=json_decode(stream_get_contents(STDIN),true); echo is_array($c) && isset($c[0]["id"]) ? $c[0]["id"] : "";')
    ${2:-cw} /api/gather-fields -u "admin:$1" -H 'Content-Type: application/json' \
        -d "{\"connectionId\": \"$ID\", \"ns\": \"family.recipes\", \"query\": {}, \"sampleSize\": 10}" | php -r '$r=json_decode(stream_get_contents(STDIN),true); echo isset($r["docsProcessed"]) ? $r["docsProcessed"] : "none";'
}
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F97") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with MongoDB and Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(@file_get_contents($f),true) ?: []; $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
# Compass Web before MongoDB is set up: refuses to start
install_app
listening 8087 && fail 'started without MongoDB' || pass 'not started while the MongoDB app is missing (it says so)'
sh $P/compass-web/stop.sh $P/compass-web > /dev/null 2>&1
install_app mongodb
wait_port 27017 120 && i=0 && until [ -s $P/_mongodb/password ] || [ $i -ge 60 ]; do sleep 2; i=$((i + 2)); done
[ -s $P/_mongodb/password ] && pass 'MongoDB answering, its administrator made' || { fail "MongoDB: $(tail -n 5 /tmp/debug_apkg)"; exit 1; }
MPW=$(cat $P/_mongodb/password)
(MONGO_PW="$MPW" HOME=/tmp $MBIN/mongosh --quiet --norc --port 27017 --eval "db.getSiblingDB('admin').auth('admin', process.env.MONGO_PW);
    db.getSiblingDB('family').recipes.insertMany([{ name: 'Soup' }, { name: 'Cake' }, { name: 'Tea' }])" > /dev/null 2>&1)

echo '== started'
sh $P/compass-web/start.sh $P/compass-web > /tmp/start.log 2>&1
wait_port 8087 60 && pass 'answering on 8087' || { fail "not answering: $(tail -n 5 /tmp/debug_apkg; tail -n 5 $D/compass-web.log)"; exit 1; }
PID=$(cat /var/run/compass-web.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 66 ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] \
    && ! tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$MPW\|$(cat $D/password)" \
    && pass "runs as its own user (66), its password root's, no password on its command line" || fail "user: $(awk '/^Uid:/' /proc/$PID/status) $(tr '\0' ' ' < /proc/$PID/cmdline)"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
PW=$(cat $D/password)
[ "$(cw /healthz -o /dev/null -w '%{http_code}')" = 200 ] && [ "$(cw / -o /dev/null -w '%{http_code}')" = 401 ] \
    && [ "$(cw /api/connection-info -o /dev/null -w '%{http_code}')" = 401 ] && [ "$(cw / -u admin:wrong-password-1 -o /dev/null -w '%{http_code}')" = 401 ] \
    && pass 'nothing without its login (its health check aside), a wrong password refused' || fail "no login: $(cw / -o /dev/null -w '%{http_code}')"
cw / -u "admin:$PW" | grep -qi 'compass' && pass "its web interface with its login" || fail "page: $(cw / -u "admin:$PW" | head -c 200)"
N=$(fields "$PW")
[ "$N" = 3 ] && pass "connected to MongoDB as its administrator: a collection's 3 documents read through it" || fail "MongoDB through it: $N / $(cw /connection-info -u "admin:$PW" | head -c 600) / $(cw /gather-fields -u "admin:$PW" -H 'Content-Type: application/json' -d "{\"connectionId\": \"$ID\", \"ns\": \"family.recipes\", \"query\": {}, \"sampleSize\": 10}" | head -c 400)"

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8087' $P/_nginx/sites/60-app-compass.conf 2>/dev/null && [ "$(site / -o /dev/null -w '%{http_code}')" = 401 ] \
    && site / -u "admin:$PW" | grep -qi 'compass' && [ "$(fields "$PW" site)" = 3 ] \
    && pass "its site https://compass.$DOMAIN: its login asked for, then its interface and MongoDB" || fail "site: $(ls $P/_nginx/sites; cat $P/_nginx/apps.json | head -c 600; cat $P/compass-web/nginx.json; php $P/nginx/lib/sites.php generate $P/_nginx 2>&1 | tail -n 5; ls $P/_nginx/sites; grep -i 'nginx\|sites' /tmp/debug_apkg | tail -n 6)"

echo '== its page'
page_up compass-web
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"0.5.2"' ] && [ "$(echo "$ST" | j '$d["mongodb"]')" = true ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://compass.$DOMAIN/\"" ] \
    && pass "the page: Compass Web 0.5.2 answering, MongoDB set up, its address https://compass.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cw / -u admin:Brand.New-Password_1 -o /dev/null -w '%{http_code}')" = 200 ] \
    && [ "$(cw / -u "admin:$PW" -o /dev/null -w '%{http_code}')" = 401 ] && pass 'a new password from the page: in use (restarted), the old one refused' || fail "new password: $R"
PW=Brand.New-Password_1
page_up mongodb
R=$(post set_password -d password=Mongo.New-Password_2)
wait_port 8087 60; sleep 2
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(fields "$PW")" = 3 ] && pass "MongoDB's administrator given a new password on its page: Compass Web follows it (restarted)" \
    || fail "follows MongoDB: $R $(fields "$PW") $(tail -n 3 $D/compass-web.log)"
page_up compass-web

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && pass 'on the network too (0.0.0.0:8087)' || fail "listen all: $R"
post listen -d listen=local > /dev/null
! listens_beyond && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q compass-web- /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-compass.conf ] && pass 'its cron lines and site gone' || fail 'left behind'
