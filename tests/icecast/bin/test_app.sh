#!/bin/sh
# The app itself, on the NAS's glibc (2.31) with WD's restrictions (/dev/urandom readable by root only): its user and
# first start (generated passwords, its configuration), the station from a folder (ezstream and ffmpeg: an MP3 stream,
# each track's title, skipping, new music, hidden folders and other files left out), a live broadcast (and a wrong
# password refused), listening only on the NAS itself, stopping
A=/mnt/HD/HD_a2/Nas_Prog/icecast; D=/mnt/HD/HD_a2/Nas_Prog/_icecast; R=$D/run
U=http://127.0.0.1:8000
. /t/bin/setup.sh
# (& | and \ escaped: they mean something to sed)
set_setting() { sed -i "s|^$1=.*|$1=$(printf '%s' "$2" | sed 's/[&|\\]/\\&/g')|" $D/settings; }
status() { curl -s $U/status-json.xsl; }
# The title on air on a mount ($1), from Icecast's status
title() { status | php -r '$s = json_decode(stream_get_contents(STDIN), true)["icestats"]["source"] ?? []; if (isset($s["listenurl"])) $s = [$s];
	foreach ($s as $m) if (parse_url($m["listenurl"], PHP_URL_PATH) === $argv[1]) echo $m["title"] ?? "(none)";' "$1"; }

echo "== first start"
sh $A/ice_ctl.sh start > /tmp/start.log 2>&1; cat /tmp/start.log
[ "$(id -u icecast)" = 82 ] && pass "its own user (82)" || fail "user: $(id icecast)"
[ "$(curl -s -o /dev/null -w '%{http_code}' $U/status-json.xsl)" = 200 ] && pass "answering on 8000" || { fail "not answering"; cat $R/logs/*.log; exit 1; }
[ "$(cat $D/admin_password | wc -c)" = 20 ] && [ "$(cat $D/source_password | wc -c)" = 20 ] && [ "$(stat -c '%U %a' $D/admin_password $D/settings | tr '\n' ' ')" = "root 600 root 600 " ] \
	&& pass "generated admin and source passwords (root's only)" || fail "passwords: $(ls -l $D)"
[ "$(stat -c '%U %a' $R/icecast.xml)" = "icecast 600" ] && grep -q "<source-password>$(cat $D/source_password)</source-password>" $R/icecast.xml \
	&& pass "its configuration: its user's only" || fail "config: $(ls -l $R)"
! grep -q "PRNG\|hostname> not configured" $R/logs/console.log $R/logs/error.log && [ -s $R/prng-seed ] \
	&& pass "no warnings (its random seed made by root: WD's /dev/urandom is root's only)" || fail "warnings: $(cat $R/logs/console.log)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u admin:$(cat $D/admin_password) $U/admin/stats.xsl)" = 200 ] && \
	[ "$(curl -s -o /dev/null -w '%{http_code}' -u admin:wrong $U/admin/stats.xsl)" = 401 ] && pass "its admin pages: the admin password, not another" || fail "admin pages"

echo "== the station from a folder"
set_setting AUTODJ 1; set_setting SHUFFLE 0; set_setting STATION_DESCRIPTION 'Tones & "quotes" <test>'
sh $A/ice_ctl.sh restart > /dev/null 2>&1; sleep 4
grep -c . $R/playlist.m3u > /tmp/n; [ "$(cat /tmp/n)" = 3 ] && ! grep -q "hidden\|notes" $R/playlist.m3u \
	&& pass "its playlist: 3 tracks (a hidden folder and other files left out)" || fail "playlist: $(cat $R/playlist.m3u)"
curl -s -m 4 -o /tmp/s.mp3 $U/radio
[ "$(stat -c %s /tmp/s.mp3)" -gt 20000 ] && [ "$(head -c 2 /tmp/s.mp3 | od -An -tx1 | tr -d ' ')" = fffb ] \
	&& pass "an MP3 stream on /radio ($(stat -c %s /tmp/s.mp3) bytes in 4 seconds)" || fail "stream: $(head -c 100 /tmp/s.mp3); $(tail -n 5 $R/logs/ezstream.log)"
T1=$(title /radio)
echo "$T1" | grep -q "Song\|Tone" && pass "the track's title on air: $T1" || fail "title: $T1 / $(status)"
status | grep -qF 'Tones & \"quotes\" <test>' && pass "the station's description, characters and all" || fail "description: $(status | head -c 600)"
sh $A/ice_ctl.sh skip; sleep 3; T2=$(title /radio)
[ -n "$T2" ] && [ "$T2" != "$T1" ] && pass "next track: $T2" || fail "skip: $T1 -> $T2"
sh $A/ice_ctl.sh skip; sleep 3; T3=$(title /radio)
[ -n "$T3" ] && [ "$T3" != "$T2" ] && pass "and the next, a file with quotes and an ampersand in its name: $T3" || fail "awkward name: $T3; $(tail -n 5 $R/logs/ezstream.log)"
cp "/mnt/HD/HD_a2/Public/Shared Music/02 second.mp3" "/mnt/HD/HD_a2/Public/Shared Music/03 new.mp3"; chmod a+r "/mnt/HD/HD_a2/Public/Shared Music/03 new.mp3"
sh $A/ice_ctl.sh playlist > /dev/null
[ "$(grep -c . $R/playlist.m3u)" = 4 ] && kill -0 "$(cat /var/run/ezstream.pid)" && pass "new music found, without stopping the station" || fail "rescan"

echo "== a live broadcast"
# (as broadcasting software sends it: a stream of unknown length - chunked)
curl -s -m 10 --limit-rate 24k -X PUT -u source:$(cat $D/source_password) -H 'Content-Type: audio/mpeg' -H 'Expect:' \
	-H 'Ice-Name: Live Show' -T - $U/live < "/mnt/HD/HD_a2/Public/Shared Music/02 second.mp3" > /dev/null 2>&1 &
sleep 3
status | grep -q '"listenurl":"http://[^"]*/live"' && pass "a live stream on /live, alongside the station" || fail "live: $(status | head -c 500)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 -X PUT -u source:wrong -H 'Content-Type: audio/mpeg' -H 'Expect:' -T - $U/live2 < /tmp/one.wav)" = 401 ] \
	&& pass "a wrong broadcasting password refused" || fail "wrong source password accepted"
kill %1 2>/dev/null; wait 2>/dev/null

echo "== the NAS itself only, stopping"
set_setting LISTEN local; sh $A/ice_ctl.sh restart > /dev/null 2>&1
grep -q '<bind-address>127.0.0.1</bind-address>' $R/icecast.xml && [ "$(curl -s -o /dev/null -w '%{http_code}' $U/status-json.xsl)" = 200 ] \
	&& pass "only on 127.0.0.1 (for the Nginx app)" || fail "local"
sh $A/ice_ctl.sh stop > /dev/null; sleep 1
[ "$(ps | grep -c '[b]inaries/icecast\|[b]inaries/ezstream')" = 0 ] && pass "stopped: Icecast and the station" || fail "still running: $(ps | grep binaries)"
