#!/bin/sh
# The management page's API (on this image's PHP), as the dashboard calls it - with an admin's WD session and the page's
# CSRF token - against a running Icecast
A=/mnt/HD/HD_a2/Nas_Prog/icecast; D=/mnt/HD/HD_a2/Nas_Prog/_icecast; M='/mnt/HD/HD_a2/Public/Shared Music'
. /t/bin/setup.sh
mkdir -p /var/www/apps && ln -s $A/manage /var/www/apps/icecast
echo "PHP $(php -r 'echo PHP_VERSION;')"
sh $A/ice_ctl.sh start > /dev/null 2>&1
echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &
sleep 1
B=http://127.0.0.1:8080/apps/icecast; CK='Cookie: PHPSESSID=adminsession123'; U=http://127.0.0.1:8010
T=$(curl -s -H "$CK" $B/index.php | sed -n 's/.*let csrf *= "\([^"]*\)".*/\1/p')
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# The station's settings as the page sends them, with changes ($@: more -d)
settings() { post settings -d station_name='NAS Radio' -d station_description= -d listen=all -d max_listeners=50 -d autodj=1 \
    --data-urlencode "music_folder=$M" -d mount=radio -d bitrate=128 -d shuffle=0 "$@"; }

ST=$(get status)
[ "$(echo "$ST" | j '$d["running"]')" = true ] && [ "$(echo "$ST" | j '$d["settings"]["autodj"]')" = false ] \
    && pass "status: running $(echo "$ST" | j '$d["version"]'), the station off at first" || fail "status: $(echo "$ST" | cut -c1-300)"
[ "$(code -H 'X-Requested-With: XMLHttpRequest' $B/api.php?action=status)" = 403 ] && pass 'without a NAS login: refused' || fail 'no session allowed'
[ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d name=admin "$B/api.php?action=password")" = 403 ] && pass 'a wrong CSRF token: refused' || fail 'csrf'
AP=$(post password -d name=admin | j '$d["password"]' | tr -d '"')
[ "$AP" = "$(cat $D/admin_password)" ] && [ "$(code -u admin:$AP $U/admin/stats.xsl)" = 200 ] && pass 'the admin password shown (and it works)' || fail 'admin password'

echo '== the station'
R=$(settings)
sleep 4; ST=$(get status)
[ "$(echo "$ST" | j '$d["station_running"]')" = true ] && [ "$(echo "$ST" | j '$d["tracks"]')" = 3 ] && echo "$ST" | j '$d["mounts"][0]' | grep -q '"mount":"/radio"' \
    && pass "turned on: on air at /radio with 3 tracks - $(echo "$ST" | j '$d["mounts"][0]')" || fail "station: $R $(echo "$ST" | cut -c1-400)"
T1=$(echo "$ST" | j '$d["mounts"][0]["title"]'); post skip -d confirm=1 > /dev/null; sleep 3
T2=$(get status | j '$d["mounts"][0]["title"]'); [ "$T1" != "$T2" ] && pass "next track: $T1 -> $T2" || fail 'skip'
cp "$M/02 second.mp3" "$M/04 another.mp3"; chmod a+r "$M/04 another.mp3"
post rescan -d confirm=1 > /dev/null; [ "$(get status | j '$d["tracks"]')" = 4 ] && pass 'new music found' || fail 'rescan'
settings -d mount=Bad/Name | grep -q "station's address" && settings -d bitrate=100 | grep -q 'Unknown bitrate' \
    && settings -d station_name= | grep -q 'Give the station a name' && settings -d max_listeners=0 | grep -q 'Listeners at once' \
    && settings --data-urlencode 'music_folder=/mnt/HD/HD_a2/Nas_Prog/_icecast' | grep -q 'not in Nas_Prog' \
    && settings --data-urlencode "music_folder=$M/missing" | grep -q 'No such folder' \
    && pass 'refused: a bad address, an unknown bitrate, no name, no listeners, Nas_Prog, a missing folder' || fail 'settings checks'
mkdir -p /mnt/HD/HD_a2/Public/Private && chmod 700 /mnt/HD/HD_a2/Public/Private
settings --data-urlencode 'music_folder=/mnt/HD/HD_a2/Public/Private' | grep -q "can't read" && pass "refused: a folder Icecast's user can't read" || fail 'unreadable folder'
settings -d mount=music -d bitrate=192 -d station_name='Test FM' > /dev/null; sleep 4
ST=$(get status); echo "$ST" | j '$d["mounts"][0]' | grep -q '"mount":"/music".*"name":"Test FM".*bitrate=192' \
    && pass "a new address, name and quality: $(echo "$ST" | j '$d["mounts"][0]')" || fail "changed station: $(echo "$ST" | j '$d["mounts"]')"

echo '== passwords, settings'
OLD=$(cat $D/source_password)
NEW=$(post new_password -d name=source | j '$d["password"]' | tr -d '"'); sleep 4
[ "$NEW" != "$OLD" ] && [ "$(code -m 4 -X PUT -u source:$OLD -H 'Content-Type: audio/mpeg' -H 'Expect:' -T - $U/live < /tmp/one.wav)" = 401 ] \
    && [ "$(get status | j '$d["station_running"]')" = true ] && echo "$(get status | j '$d["mounts"]')" | grep -q '/music' \
    && pass 'a new broadcasting password: the old one refused, the station still on air (it uses the new one)' || fail 'new source password'
settings -d listen=local -d mount=music > /dev/null
grep -q '<bind-address>127.0.0.1</bind-address>' $D/run/icecast.xml && pass 'only through the Nginx app: on 127.0.0.1' || fail 'local'
settings -d autodj=0 -d mount=music > /dev/null; sleep 1
[ "$(get status | j '$d["station_running"]')" = false ] && [ "$(get status | j 'count($d["mounts"])')" = 0 ] && pass 'the station turned off' || fail 'station off'
post restart -d confirm=1 > /dev/null
[ "$(get status | j '$d["running"]')" = true ] && pass 'restarted' || fail 'restart'
