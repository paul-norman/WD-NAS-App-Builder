#!/bin/sh
# changedetection.io from its package (tests/common/nas.sh), with the Nginx and ntfy apps (tests/changedetection/with):
# its first start as its own user, only on the NAS itself, its password (made by the app: logging in needs it), the
# page's password (shown, a typed one, a generated one), local network pages refused then allowed, a watched page's
# change noticed and sent to the ntfy app's topic, the browser setting (none, another machine's, the recipe's - and the
# recipe's hooks), its site through Nginx (its alerts' links), the network setting, a restart keeping its watches,
# removal
. /t/common/nas.sh changedetection
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
U=http://127.0.0.1:5000
JAR=/tmp/jar
site() { p=$1; shift; curl -sk -m 10 --resolve "changes.$DOMAIN:443:127.0.0.1" "$@" "https://changes.$DOMAIN$p"; }
# Logs in to changedetection.io with a password (its form, with its CSRF token): login <password> - then 0 if it let us in
login() {
    rm -f $JAR
    t=$(curl -s -c $JAR -b $JAR $U/login | sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' | head -n 1)
    curl -s -o /dev/null -c $JAR -b $JAR --data-urlencode "password=$1" --data-urlencode "csrf_token=$t" $U/login
    [ "$(curl -s -o /dev/null -w '%{http_code}' -b $JAR $U/)" = 200 ]
}
# Its API (its key, from its own settings): api <path> [curl options]
api() { p=$1; shift; curl -s -m 10 -H "x-api-key: $(php -r 'echo json_decode(file_get_contents($argv[1]), true)["settings"]["application"]["api_access_token"];' $D/datastore/changedetection.json)" "$@" "$U$p"; }
pid_env() { tr '\0' '\n' < /proc/$(cat /var/run/changedetection.pid)/environ; }
up() { wait_port 5000 180 && i=0 && while [ $i -lt 60 ] && ! curl -s -m 3 $U/login | grep -q 'type="password"'; do sleep 1; i=$((i + 1)); done; }

echo '== with Nginx and ntfy'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(@file_get_contents($f),true) ?: []; $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
install_app ntfy
wait_port 2586 30 && pass 'ntfy answering' || fail "ntfy: $(tail -n 5 /tmp/start.log)"

echo '== first start'
install_app
up && pass 'answering on 5000' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 10 $D/changedetection.out)"; exit 1; }
PID=$(cat /var/run/changedetection.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 51 ] && [ "$(stat -c '%U %a' $D/datastore)" = 'changedetection 700' ] \
    && [ "$(stat -c '%U %a' $D/password)" = 'root 600' ] && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass 'runs as its own user (51), its datastore its own; its password and settings root'"'"'s only' || fail "users: $(stat -c '%n %U %G %a' $D $D/datastore $D/password $D/settings)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1388") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
PW=$(cat $D/password)
[ ${#PW} = 20 ] && ! pid_env | grep -q "$PW" && pid_env | grep -q '^SALTED_PASS=' && ! grep -rq "$PW" $D/datastore \
    && pass 'a password made at the first start (20 characters): changedetection.io only gets it hashed' || fail "password: ${#PW} $(pid_env | grep SALTED)"
L=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $U/)
echo "$L" | grep -q '^30[1-8] .*login' && ! login 'Wrong-password-1' && login "$PW" \
    && pass 'its pages need the password (a wrong one refused)' || fail "login: $L"

echo '== its page'
page_up changedetection
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"0.70.3"' ] && [ "$(echo "$ST" | j '$d["browser"]["url"]')" = '""' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://changes.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["ntfy"]')" = true ] \
    && pass "the page: changedetection.io 0.70.3 answering, no browser, its address https://changes.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post show_password -d confirm=1 | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows its password' || fail 'show password'
P1=$(curl -s -H "$CK" $PAGE/index.php)
echo "$P1" | grep -q '<input type="password" data-cd="new-password"' && echo "$P1" | grep -q 'data-show-for="new-password">Show' \
    && pass 'the page: a password field (hidden as typed) with Show' || fail 'password field'

echo '== passwords'
[ "$(post new_password -d password=short | j '$d["ok"]')" = false ] && [ "$(post new_password --data-urlencode "password=$(printf 'Control\001char-pass')" | j '$d["ok"]')" = false ] \
    && pass 'a short password, and one with a control character, refused' || fail 'bad password accepted'
NP=$(post new_password --data-urlencode 'password=Caret^Pass word!1'); up
[ "$(echo "$NP" | j '$d["password"]')" = '"Caret^Pass word!1"' ] && login 'Caret^Pass word!1' && ! login "$PW" && [ "$(cat $D/password)" = 'Caret^Pass word!1' ] \
    && pass 'a typed password (symbols and a space): in use, the old one refused' || fail "typed: $NP"
GP=$(post new_password -d password= | j '$d["password"]' | tr -d '"'); up
[ ${#GP} = 20 ] && login "$GP" && pass 'a generated one (20 characters)' || fail "generated: $GP"

echo '== watching a page (on the local network), alerts to ntfy'
mkdir -p /tmp/www && printf '<html><body><p>Price: 10</p></body></html>\n' > /tmp/www/page.html
(cd /tmp/www && exec python3 -m http.server 8997 --bind 127.0.0.1 > /tmp/www.log 2>&1 &)
wait_port 8997 10
# (changedetection.io takes the watch, but refuses to fetch it)
B=$(api /api/v1/watch -H 'Content-Type: application/json' -d '{"url": "http://127.0.0.1:8997/page.html"}' | j '$d["uuid"]' | tr -d '"')
i=0; while [ $i -lt 60 ] && ! api /api/v1/watch/$B | grep -q 'private/reserved'; do sleep 1; i=$((i + 1)); done
api /api/v1/watch/$B | grep -q 'private/reserved' && [ "$(api /api/v1/watch/$B/history | j 'count($d)')" = 0 ] \
    && pass 'a local network page refused by default (not fetched: "private/reserved IP address")' || fail "local page: $(api /api/v1/watch/$B | head -c 300)"
api /api/v1/watch/$B -X DELETE > /dev/null
R1=$(post settings -d 'ntfy_topic=no spaces' -d local_addresses=1)
R2=$(post settings -d ntfy_topic=changes -d local_addresses=1); up
grep -q '"ntfy://tk_[A-Za-z0-9]*@127.0.0.1:2586/changes"' $D/datastore/changedetection.json && pid_env | grep -qx 'ALLOW_IANA_RESTRICTED_ADDRESSES=true' \
    && [ "$(echo "$R1" | j '$d["ok"]')" = false ] && [ "$(echo "$R2" | j '$d["ok"]')" = true ] \
    && pass "an ntfy topic (not one with spaces) and local pages allowed: the ntfy app's address in its alerts, with ntfy's token" || fail "settings: $R1 $R2 $(grep -A3 notification_urls $D/datastore/changedetection.json | head -5)"
W=$(api /api/v1/watch -H 'Content-Type: application/json' -d '{"url": "http://127.0.0.1:8997/page.html", "title": "Test page"}' | j '$d["uuid"]' | tr -d '"')
i=0; while [ $i -lt 90 ] && [ "$(api /api/v1/watch/$W/history | j 'count($d)')" != 1 ]; do sleep 1; i=$((i + 1)); done
printf '<html><body><p>Price: 12</p></body></html>\n' > /tmp/www/page.html
api "/api/v1/watch/$W?recheck=1" > /dev/null
i=0; while [ $i -lt 90 ] && [ "$(api /api/v1/watch/$W/history | j 'count($d)')" != 2 ]; do sleep 1; i=$((i + 1)); done
[ -n "$W" ] && [ "$(api /api/v1/watch/$W/history | j 'count($d)')" = 2 ] && pass 'a watched page: its change noticed (two versions)' || fail "watch: $W $(api /api/v1/watch/$W | head -c 300)"
i=0; while [ $i -lt 30 ]; do M=$(curl -s -m 5 -H "Authorization: Bearer $(cat $P/_ntfy/token)" 'http://127.0.0.1:2586/changes/json?poll=1'); echo "$M" | grep -q 'Price: 12\|Test page\|127.0.0.1:8997' && break; sleep 2; i=$((i + 1)); done
echo "$M" | grep -q 'Price: 12\|Test page\|127.0.0.1:8997' && pass 'the change arrives in the ntfy app' || fail "ntfy: $(echo "$M" | head -c 300) $(grep -i 'notif\|apprise' $D/changedetection.out | tail -n 3)"
post settings -d ntfy_topic= -d local_addresses=1 > /dev/null; up
! grep -q '127.0.0.1:2586' $D/datastore/changedetection.json && pass 'no topic: the ntfy address removed (only the app'"'"'s own)' || fail 'topic not removed'

echo '== the browser'
[ "$(post browser -d browser=local | j '$d["ok"]')" = false ] && [ "$(post browser -d 'browser=file:///etc/passwd' | j '$d["ok"]')" = false ] \
    && pass 'refused: the recipe'"'"'s browser without the recipe, an address that isn'"'"'t a browser'"'"'s' || fail 'bad browser accepted'
R=$(post browser -d browser=http://192.0.2.10:9222); up
[ "$(echo "$R" | j '$d["ok"]')" = true ] && pid_env | grep -qx 'PLAYWRIGHT_DRIVER_URL=http://192.0.2.10:9222' && [ "$(get status | j '$d["browser"]["version"]')" = '""' ] \
    && pass "another machine's browser: changedetection.io's Chrome fetcher uses it (not answering here)" || fail "other browser: $R $(pid_env | grep PLAYWRIGHT)"
# The recipe's browser: a stand-in for Chrome's DevTools port, and the recipe's folder
mkdir -p /tmp/cdp/json $P/_changedetection-browser && printf '{"Browser": "Chrome/156.0.8078.79"}\n' > /tmp/cdp/json/version && : > $P/_changedetection-browser/compose.yaml
(cd /tmp/cdp && exec python3 -m http.server 9222 --bind 127.0.0.1 > /tmp/cdp.log 2>&1 &)
wait_port 9222 10
H=$(cd $P/_changedetection-browser && sh /t/recipe/hooks/post_install.sh 2>&1); up
ST=$(get status)
grep -qx 'BROWSER_URL=http://127.0.0.1:9222' $D/settings && pid_env | grep -qx 'PLAYWRIGHT_DRIVER_URL=http://127.0.0.1:9222' && [ "$(echo "$ST" | j '$d["browser"]["local"]')" = true ] \
    && [ "$(echo "$ST" | j '$d["browser"]["version"]')" = '"Chrome/156.0.8078.79"' ] && echo "$H" | grep -q 'Chrome is answering: Chrome/156' \
    && pass "the recipe's post_install hook: the app uses its Chrome (the page shows its version)" || fail "recipe on: $H $(echo "$ST" | j '$d["browser"]')"
H=$(cd $P/_changedetection-browser && sh /t/recipe/hooks/pre_uninstall.sh 2>&1); up
grep -qx 'BROWSER_URL=' $D/settings && ! pid_env | grep -q PLAYWRIGHT_DRIVER_URL && echo "$H" | grep -q 'no longer uses a browser' \
    && pass "the recipe's pre_uninstall hook: no browser (plain requests)" || fail "recipe off: $H $(grep BROWSER $D/settings)"
[ "$(post browser -d browser=local | j '$d["ok"]')" = true ] && up && grep -qx 'BROWSER_URL=http://127.0.0.1:9222' $D/settings && post browser -d browser= > /dev/null && up \
    && grep -qx 'BROWSER_URL=' $D/settings && pass "the page: the recipe's browser, then none" || fail "page browser: $(grep BROWSER $D/settings)"

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:5000' $P/_nginx/sites/60-app-changes.conf 2>/dev/null && site /login | grep -q 'type="password"' \
    && pid_env | grep -qx "BASE_URL=https://changes.$DOMAIN/" \
    && pass "its site https://changes.$DOMAIN/ (its login page), the address in its alerts' links" || fail "site: $(ls $P/_nginx/sites; pid_env | grep BASE_URL)"

echo '== on the network'
RS=$(post listen -d listen=all); up
[ "$(echo "$RS" | j '$d["ok"]')" = true ] && awk 'NR > 1 && $4 == "0A" && index($2, ":1388") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && pass 'on the network too (port 5000)' || fail "listen all: $RS"
post listen -d listen=local > /dev/null; up
awk 'NR > 1 && $4 == "0A" && index($2, ":1388") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'still on the network' || pass 'and back to the NAS only'

echo '== restart'
sh $P/changedetection/stop.sh $P/changedetection > /dev/null 2>&1
listening 5000 && fail 'still answering once stopped' || true
sh $P/changedetection/start.sh $P/changedetection > /tmp/start.log 2>&1
up && [ "$(api /api/v1/watch/$W/history | j 'count($d)')" = 2 ] && login "$GP" \
    && pass 'restarted: its watch and its history kept, the same password' || fail "restart: $(tail -n 5 /tmp/start.log)"
grep -E '\| (ERROR|CRITICAL) ' $D/changedetection.out | head -3

echo '== removal'
finish_app
! grep -q changedetection-daily /var/spool/cron/crontabs/root && [ -d $D/datastore/$W ] && [ -s $D/password ] \
    && pass 'its cron line gone; its watches and password kept' || fail 'removal'
