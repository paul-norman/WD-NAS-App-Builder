#!/bin/sh
# The management page's API (on this image's PHP), as the dashboard calls it - with an admin's WD session and the page's
# CSRF token - against a running Audiobookshelf
A=/mnt/HD/HD_a2/Nas_Prog/audiobookshelf; D=/mnt/HD/HD_a2/Nas_Prog/_audiobookshelf; P=/mnt/HD/HD_a2/Public
. /t/bin/setup.sh
mkdir -p /var/www/apps && ln -s $A/manage /var/www/apps/audiobookshelf
echo "PHP $(php -r 'echo PHP_VERSION;')"
sh $A/abs_ctl.sh start > /dev/null 2>&1
echo "administrators:x:1001:admin" >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &
sleep 1
B=http://127.0.0.1:8080/apps/audiobookshelf; CK='Cookie: PHPSESSID=adminsession123'; U=http://127.0.0.1:13378
T=$(curl -s -H "$CK" $B/index.php | sed -n 's/.*var csrf = "\([^"]*\)".*/\1/p')
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
login() { curl -s -X POST -H 'Content-Type: application/json' -d "{\"username\":\"root\",\"password\":\"$1\"}" $U/login; }

ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["libraries"]')" = '[]' ] && [ "$(echo "$ST" | j '$d["password_known"]')" = true ] \
	&& pass "status: running $(echo "$ST" | j '$d["version"]'), no libraries yet" || fail "status: $(echo "$ST" | cut -c1-300)"
[ "$(code -H 'X-Requested-With: XMLHttpRequest' $B/api.php?action=status)" = 403 ] && pass "without a NAS login: refused" || fail "no session allowed"
[ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d show=1 "$B/api.php?action=password")" = 403 ] && pass "a wrong CSRF token: refused" || fail "csrf"
PW=$(post password -d show=1 | j '$d["password"]' | tr -d '"')
[ "$PW" = "$(cat $D/root_password)" ] && pass "the root password shown" || fail "password"

echo "== libraries"
TOKEN=$(login "$PW" | j '$d["user"]["accessToken"]' | tr -d '"')
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"name\":\"Audiobooks\",\"folders\":[{\"fullPath\":\"$P/Audiobooks\"}],\"mediaType\":\"book\"}" $U/api/libraries > /tmp/lib.json
L=$(j '$d["id"]' < /tmp/lib.json | tr -d '"'); curl -s -X POST -H "Authorization: Bearer $TOKEN" $U/api/libraries/$L/scan > /dev/null; sleep 6
mkdir -p $P/Locked && chmod 700 $P/Locked
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"name\":\"Locked\",\"folders\":[{\"fullPath\":\"$P/Locked\"}],\"mediaType\":\"podcast\"}" $U/api/libraries > /dev/null
ST=$(get status)
echo "$ST" | j '$d["libraries"][0]' | grep -q '"name":"Audiobooks".*"items":2' && echo "$ST" | j '$d["libraries"][1]["folders"][0]["can"]' | grep -q none \
	&& pass "its libraries, with their items, and a folder it can't open flagged: $(echo "$ST" | j '$d["libraries"]')" || fail "libraries: $(echo "$ST" | j '$d["libraries"]')"
S1=$(stat -c %Y $D/page_token); sleep 1; get status > /dev/null
[ "$(stat -c '%a' $D/page_token)" = 600 ] && [ "$(stat -c %Y $D/page_token)" = "$S1" ] && [ "$(grep -c 'User "root" logged in' $D/audiobookshelf.log)" -le 2 ] \
	&& pass "the page's login is kept (root only) and reused - not a login every refresh" || fail "token reuse: $(grep -c 'logged in' $D/audiobookshelf.log)"

echo "== passwords, settings"
NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"')
[ "$NEW" != "$PW" ] && [ "$(code -X POST -H 'Content-Type: application/json' -d "{\"username\":\"root\",\"password\":\"$NEW\"}" $U/login)" = 200 ] \
	&& [ "$(get status | j 'count($d["libraries"])')" = 2 ] && pass "a new password (and the page logs in with it)" || fail "new password"
post settings -d listen=local -d 'local_feeds=192.168.1.20, Podcasts.Home' > /dev/null
grep -qx 'LOCAL_FEEDS=192.168.1.20,podcasts.home' $D/settings && grep -q 'Whitelisting: 192.168.1.20,podcasts.home' $D/audiobookshelf.log \
	&& [ "$(code $U/status)" = 200 ] && pass "podcast feeds on the home network allowed (Audiobookshelf's own list)" || fail "local feeds: $(cat $D/settings)"
post settings -d listen=all -d 'local_feeds=bad host!' | grep -q "host names" && pass "a bad host name refused" || fail "feed check"
[ "$(ps -o args | grep '[d]ist-server' | wc -l)" = 1 ] && pass "one Audiobookshelf running" || fail "processes: $(ps -o args | grep dist-server)"
post restart -d confirm=1 > /dev/null
[ "$(get status | j '$d["answering"]')" = true ] && pass "restarted" || fail "restart"
