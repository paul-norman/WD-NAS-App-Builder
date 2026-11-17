#!/bin/sh
# MeTube from its package (tests/common/nas.sh), with the Nginx app (tests/metube/with): its first start as its own user
# (in the share group), MeTube and the Watch page only on the NAS itself, people from the page, logging in to the Watch
# page, a download (a local test video) into one person's folder - not seen by another, played with ranges - watched,
# kept, cleaned up (by the Watch page's own watched date and by a stand-in Jellyfin's), deleted; a stand-in Plex
# checked; yt-dlp updated from a stand-in package index (a broken one refused), the site through Nginx, the network
# setting, a restart, removal keeping the data
. /t/common/nas.sh metube
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
W=http://127.0.0.1:8086
DL="$V/Public/Watch Later"
PY=$P/metube/binaries/python/bin/python3
# The test video comes from this NAS itself: MeTube refuses private addresses unless told otherwise (only here)
export METUBE_ALLOW_PRIVATE=true
# SponsorBlock: the stand-in (stubs.py, with the media server)
export WATCH_SPONSORBLOCK_URL=http://127.0.0.1:8997
# A file name in a URL (its spaces and brackets encoded)
enc() { echo "$1" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g'; }
# A Watch page request as a person (their cookies in /tmp/jar-<name>): wa <name> <path> [curl options]; wpost <name> <path> <json>
wa() { n=$1; p=$2; shift 2; curl -s -b /tmp/jar-$n -c /tmp/jar-$n "$@" "$W$p"; }
wpost() { wa "$1" "$2" -H 'Content-Type: application/json' -H 'X-Requested-With: watch' -d "$3"; }
wcode() { n=$1; p=$2; shift 2; curl -s -o /dev/null -w '%{http_code}' -b /tmp/jar-$n "$@" "$W$p"; }
login() { rm -f /tmp/jar-$1; wpost "$1" /api/login "{\"name\": \"$1\", \"password\": \"$2\"}" > /tmp/login.json; }
videos() { wa "$1" /api/videos; }
# Waits for a person's video count to reach a number
wait_videos() { i=0; while [ $i -lt 60 ]; do [ "$(videos "$1" | j 'count($d["videos"])')" = "$2" ] && return 0; sleep 2; i=$((i + 2)); done; return 1; }
site() { p=$1; shift; curl -sk -m 10 --resolve "videos.$DOMAIN:443:127.0.0.1" "$@" "https://videos.$DOMAIN$p"; }
restart_app() { sh $P/metube/stop.sh $P/metube > /dev/null 2>&1; sh $P/metube/start.sh $P/metube > /tmp/start.log 2>&1; wait_port 8086 60; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 8086 120 && wait_port 8085 60 && pass 'MeTube on 8085, the Watch page on 8086' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 10 $D/metube.log $D/watch.log)"; exit 1; }
PID=$(cat /var/run/metube.pid); WPID=$(cat /var/run/metube-watch.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 52 ] && [ "$(awk '/^Uid:/ { print $2 }' /proc/$WPID/status)" = 52 ] && [ "$(awk '/^Gid:/ { print $2 }' /proc/$PID/status)" = 1000 ] \
    && [ "$(stat -c '%U %a' $D/secret)" = 'metube 400' ] && [ "$(stat -c '%U %G %a' "$DL")" = 'metube share 2775' ] \
    && pass "both run as its own user (52, in the share group); the download folder Public/Watch Later made for it" || fail "users: $(stat -c '%n %U %G %a' $D/secret "$DL"; awk '/^(Uid|Gid):/' /proc/$PID/status)"
for port in 1F95 1F96; do
    awk -v p=":$port" 'NR > 1 && $4 == "0A" && index($2, p) { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail "port $port listens beyond the NAS"
done
pass 'both only on the NAS itself (127.0.0.1), the Nginx app being there'
curl -s http://127.0.0.1:8085/version | grep -q '"version": "2026.11.14"' && pass "MeTube 2026.11.14 answering ($(curl -s http://127.0.0.1:8085/version))" || fail "version: $(curl -s http://127.0.0.1:8085/version)"

echo '== people, from the page'
page_up metube
ST=$(get status)
[ "$(echo "$ST" | j '$d["watch"]')" = true ] && [ "$(echo "$ST" | j '$d["download_dir"]')" = "\"$DL\"" ] && [ "$(echo "$ST" | j '$d["users"]')" = '[]' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://videos.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["ytdlp"]')" = '"2026.10.26"' ] \
    && pass "the page: both running, yt-dlp 2026.10.26, the Watch page at https://videos.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 500)"
[ "$(post add_user -d name=Bad/Name | j '$d["ok"]')" = false ] && [ "$(post add_user -d name=alice -d password=short | j '$d["ok"]')" = false ] \
    && pass 'a bad name and a short password refused' || fail 'bad user accepted'
AP=$(post add_user -d name=alice -d password=Alice.Pass-1 | j '$d["password"]')
BP=$(post add_user -d name=bob | j '$d["password"]' | tr -d '"')
[ "$AP" = '"Alice.Pass-1"' ] && [ ${#BP} = 16 ] && grep -q '"hash": "pbkdf2_sha256\$100000\$' $D/users.json && ! grep -q Alice.Pass $D/users.json \
    && [ "$(stat -c '%U %a' $D/users.json)" = 'metube 640' ] && pass 'alice and bob added (only PBKDF2 hashes kept)' || fail "add: $AP $(cat $D/users.json)"

echo '== logging in'
[ "$(wcode alice /api/videos)" = 401 ] && pass 'nothing without logging in (401)' || fail 'videos without login'
login alice Wrong.Pass-1; grep -q 'Wrong name or password' /tmp/login.json && pass 'a wrong password refused' || fail "wrong password: $(cat /tmp/login.json)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"name": "alice", "password": "Alice.Pass-1"}' $W/api/login)" = 403 ] \
    && pass "another site's form can't log in (no X-Requested-With: 403)" || fail 'login without the page header'
login alice Alice.Pass-1; login bob "$BP"
[ "$(videos alice | j '$d["name"]')" = '"alice"' ] && [ "$(videos bob | j '$d["videos"]')" = '[]' ] && grep -q 'HttpOnly' /tmp/jar-alice \
    && pass 'alice and bob logged in (an HttpOnly session cookie)' || fail "login: $(videos alice | head -c 200)"
R=$(post add_user -d name=carol --data-urlencode 'password=Up^ & down!1')
login carol 'Up^ & down!1'
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(videos carol | j '$d["name"]')" = '"carol"' ] \
    && pass 'a password with symbols and spaces (^ & !) works' || fail "symbols: $R $(cat /tmp/login.json)"
[ "$(post add_user -d name=dave --data-urlencode "password=$(printf 'Control\001char')" | j '$d["ok"]')" = false ] \
    && pass 'a control character refused' || fail 'control character accepted'
post remove_user -d name=carol > /dev/null
wa alice / | grep -q '<title>Watch</title>' && wa alice /static/app.js | grep -q "api('api/videos')" && pass 'the Watch page and its script served' || fail 'page not served'
# (the page hides its login form once logged in: hidden must beat the form's own display)
wa alice /static/style.css | grep -A1 '^\[hidden\] {' | grep -q 'display: none !important' && pass 'hidden parts stay hidden (the login form, once logged in)' || fail 'no [hidden] rule'

echo '== a download'
mkdir -p /tmp/www
$P/metube/binaries/bin/ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=4:size=320x240:rate=10 -f lavfi -i sine=frequency=440:duration=4 \
    -c:v mjpeg -c:a aac -shortest "/tmp/www/Test clip.mp4"
cp "/tmp/www/Test clip.mp4" /tmp/www/second.mp4; cp "/tmp/www/Test clip.mp4" /tmp/www/third.mp4; cp "/tmp/www/Test clip.mp4" /tmp/www/abcdefghijk.mp4; cp "/tmp/www/Test clip.mp4" /tmp/www/lmnopqrstuv.mp4
(cd /tmp/www && $PY -m http.server 8999 --bind 127.0.0.1 > /tmp/http.log 2>&1 &)
wait_port 8999 10
R=$(wpost alice /api/add '{"url": "http://127.0.0.1:8999/Test%20clip.mp4", "kind": "video"}')
echo "$R" | grep -q '"status": *"ok"' && wait_videos alice 1 && pass "alice's link downloaded by MeTube, listed on her Watch page" || fail "add: $R $(videos alice | head -c 300) $(tail -n 5 $D/metube.log)"
F=$(videos alice | j '$d["videos"][0]["file"]' | tr -d '"')
[ -f "$DL/alice/$F" ] && [ "$(stat -c '%U %G' "$DL/alice/$F")" = 'metube share' ] && [ "$(stat -c '%a' "$DL/alice/$F" | cut -c2-3)" = 64 ] \
    && pass "in alice's own folder (Watch Later/alice/$F), writable by the share group" || fail "file: $(ls -la "$DL" "$DL/alice")"
E=$(enc "$F")
[ "$(videos bob | j 'count($d["videos"])')" = 0 ] && [ "$(wcode bob "/media/$E")" = 404 ] && [ "$(wcode bob "/media/../alice/$E" --path-as-is)" != 200 ] \
    && pass "bob doesn't see it, and can't fetch it (not even through ..)" || fail "bob sees alice's: $(videos bob)"
[ "$(wcode alice "/media/$E" -H 'Range: bytes=0-99')" = 206 ] && pass 'alice plays it (a range request: 206, so it can seek)' || fail 'range'
[ "$(wpost alice /api/add '{"url": "file:///etc/passwd", "kind": "video"}' | head -c 30)" = 'Give a link (https://...)' ] && pass 'only web links accepted' || fail 'file: link accepted'

echo '== watched, kept, cleaned up'
wpost alice /api/watched "{\"file\": \"$F\"}" > /dev/null
V=$(videos alice)
[ "$(echo "$V" | j '$d["videos"][0]["watched"] > 0')" = true ] && [ "$(echo "$V" | j '$d["videos"][0]["days_left"]')" = 3 ] \
    && pass 'watched: deleted in 3 days (the default)' || fail "watched: $V"
wpost alice /api/add '{"url": "http://127.0.0.1:8999/second.mp4", "kind": "video"}' > /dev/null; wait_videos alice 2
wpost alice /api/keep '{"file": "second [second].mp4", "keep": true}' > /dev/null
wpost alice /api/watched '{"file": "second [second].mp4"}' > /dev/null
# Both watched 10 days ago (as if): the kept one stays
$PY -c 'import json, sys, time; p = sys.argv[1]; s = json.load(open(p)); s["watched"] = {k: int(time.time()) - 10 * 86400 for k in s["watched"]}; json.dump(s, open(p, "w"))' $D/watch/alice.json
restart_app
sleep 3
[ ! -f "$DL/alice/$F" ] && [ -f "$DL/alice/second [second].mp4" ] && [ "$(videos alice | j '$d["videos"][0]["kept"]')" = true ] \
    && pass 'the clean-up: the video watched 10 days ago deleted, the kept one not' || fail "clean-up: $(ls "$DL/alice") $(tail -n 3 $D/watch.log)"
grep -q "clean-up: deleted alice's" $D/watch.log && pass 'logged' || fail 'clean-up not logged'
[ "$(wpost alice /api/settings '{"watched_days": 1, "unwatched_days": 0}' | head -c 2)" = '{}' ] && [ "$(videos alice | j '$d["settings"]["unwatched_days"]')" = 0 ] \
    && pass "alice's own clean-up days saved" || fail 'settings'
[ "$(wpost alice /api/settings '{"watched_days": -1, "unwatched_days": 0}' | head -c 2)" != '{}' ] && pass 'a negative number refused' || fail 'negative days'

echo '== a media server (a stand-in Jellyfin, then Plex)'
wpost alice /api/add '{"url": "http://127.0.0.1:8999/third.mp4", "kind": "video"}' > /dev/null; wait_videos alice 2
printf '{"_root": "%s", "%s/alice/third [third].mp4": %s}\n' "$DL" "$DL" "$(( $(date +%s) - 5 * 86400 ))" > /tmp/played.json
($PY /t/app/stubs.py media 8997 /tmp/played.json > /tmp/stub.log 2>&1 &)
wait_port 8997 10
R=$(post media_test -d type=jellyfin -d url=http://127.0.0.1:8997 -d token=stubtoken123)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && echo "$R" | grep -q 'Watch later' && pass "Test: Jellyfin answered, its library in the download folder found" || fail "test: $R"
[ "$(post media_test -d type=jellyfin -d url=http://127.0.0.1:8997 -d token=wrongtoken99 | j '$d["ok"]')" = false ] && pass 'a wrong key reported' || fail 'wrong key accepted'
post media_server -d type=jellyfin -d url=http://127.0.0.1:8997 -d token=stubtoken123 > /dev/null
[ "$(get status | j '$d["media_server"]["token_set"]')" = true ] && ! get status | grep -q stubtoken123 && pass 'saved; the key never shown' || fail 'media server save'
restart_app
sleep 3
[ ! -f "$DL/alice/third [third].mp4" ] && pass "watched in Jellyfin 5 days ago (alice's days: 1): deleted" || fail "jellyfin clean-up: $(ls "$DL/alice") $(tail -n 3 $D/watch.log)"
R=$(post media_test -d type=plex -d url=http://127.0.0.1:8997 -d token=)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && echo "$R" | grep -q 'Plex answered: Watch later' && pass 'Plex (the saved token kept): its library found' || fail "plex test: $R"
post media_server -d type=plex -d url=http://127.0.0.1:8997 -d token= > /dev/null
printf '{"_root": "%s", "%s/alice/second [second].mp4": %s}\n' "$DL" "$DL" "$(date +%s)" > /tmp/played.json
restart_app
[ "$(videos alice | j '$d["videos"][0]["watched_elsewhere"]')" = true ] && [ -f "$DL/alice/second [second].mp4" ] \
    && pass 'watched in Plex: shown, the kept video still kept' || fail "plex: $(videos alice)"
post media_server -d type= > /dev/null

echo '== deleting'
[ "$(wpost bob /api/delete '{"file": "second [second].mp4"}' | head -c 20)" = 'No such video' ] && [ -f "$DL/alice/second [second].mp4" ] && pass "bob can't delete alice's video" || fail 'bob deleted it'
[ "$(wpost alice /api/delete '{"file": "second [second].mp4"}')" = '{}' ] && [ ! -f "$DL/alice/second [second].mp4" ] && [ "$(videos alice | j 'count($d["videos"])')" = 0 ] \
    && pass 'alice deletes her own' || fail 'delete'

echo '== SponsorBlock and playback speed'
wpost alice /api/add '{"url": "http://127.0.0.1:8999/abcdefghijk.mp4", "kind": "video"}' > /dev/null; wait_videos alice 1
V=$(videos alice)
[ "$(echo "$V" | j '$d["videos"][0]["file"]')" = '"abcdefghijk [abcdefghijk].mp4"' ] && [ "$(echo "$V" | j '$d["videos"][0]["title"]')" = '"abcdefghijk"' ] \
    && [ "$(echo "$V" | j '$d["videos"][0]["video_id"]')" = '"abcdefghijk"' ] && [ "$(echo "$V" | j '$d["videos"][0]["cut"]')" = false ] \
    && pass 'downloads named "Title [id]": the page shows the title, knows the ID' || fail "naming: $V"
SEG="/api/segments?file=$(enc 'abcdefghijk [abcdefghijk].mp4')"
[ "$(wa alice "$SEG" | j 'array_map(function ($s) { return $s["category"]; }, $d["segments"])')" = '["selfpromo","sponsor"]' ] \
    && pass "SponsorBlock (its private lookup by hash prefix): the default categories' segments to skip, not intros, mutes or another video's" || fail "segments: $(wa alice "$SEG")"
[ "$(wcode bob "$SEG")" = 404 ] && pass "not for bob (alice's video)" || fail "bob's segments: $(wcode bob "$SEG")"
wpost alice /api/settings '{"sb_categories": ["intro"]}' > /dev/null
[ "$(wa alice "$SEG" | j 'count($d["segments"]) . $d["segments"][0]["category"]')" = '"1intro"' ] && pass 'her own categories: intros only' || fail "intro: $(wa alice "$SEG")"
wpost alice /api/settings '{"sb_skip": false}' > /dev/null
[ "$(wa alice "$SEG" | j '$d["segments"]')" = '[]' ] && pass 'skipping off: nothing to skip' || fail "skip off: $(wa alice "$SEG")"
[ "$(wpost alice /api/settings '{"sb_categories": ["adverts"]}' | head -c 13)" = 'sb_categories' ] && pass 'an unknown category refused' || fail 'unknown category'
[ "$(wpost alice /api/settings '{"speed": 1.75}')" = '{}' ] && [ "$(videos alice | j '$d["settings"]["speed"]')" = 1.75 ] \
    && [ "$(videos alice | j 'count($d["speeds"]) . "/" . max($d["speeds"])')" = '"12/3"' ] \
    && pass "her playback speed (1.75x) saved; 0.25x to 3x offered" || fail "speed: $(videos alice | j '$d["settings"]')"
[ "$(wpost alice /api/settings '{"speed": 3.25}' | head -c 5)" = 'speed' ] && [ "$(wpost alice /api/settings '{"speed": 0.3}' | head -c 5)" = 'speed' ] \
    && pass 'speeds beyond 3x or between steps refused' || fail 'bad speed accepted'
wpost alice /api/settings '{"sb_skip": true, "sb_categories": ["sponsor"], "sb_cut": true}' > /dev/null
wpost alice /api/add '{"url": "http://127.0.0.1:8999/lmnopqrstuv.mp4", "kind": "video"}' > /dev/null; wait_videos alice 2
CUT="/api/segments?file=$(enc 'lmnopqrstuv [lmnopqrstuv].mp4')"
curl -s http://127.0.0.1:8085/history | $PY -c 'import json, sys; d = json.load(sys.stdin); sys.exit(not any(i.get("sponsorblock") and "lmnopqrstuv" in (i.get("filename") or "") for i in d["done"]))' \
    && [ "$(videos alice | j '$d["videos"][0]["cut"]')" = true ] && [ "$(wa alice "$CUT" | j '$d["segments"]')" = '[]' ] \
    && [ "$(wa alice "$SEG" | j 'count($d["segments"])')" = 1 ] \
    && pass "cutting on: MeTube downloads with its sponsors cut, and the player doesn't skip in it (its times moved) - but does in the other" || fail "cut: $(videos alice | head -c 400)"
wpost alice /api/settings '{"sb_cut": false}' > /dev/null

echo '== playlists'
# A playlist: an RSS feed of three videos (yt-dlp takes it as one), added with a limit of 2
for n in 1 2 3; do cp "/tmp/www/Test clip.mp4" /tmp/www/pl$n.mp4; done
{
    echo '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Test playlist</title><link>http://127.0.0.1:8999/</link><description>t</description>'
    for n in 1 2 3; do
        echo "<item><title>Video $n</title><guid>playlist00$n</guid><enclosure url=\"http://127.0.0.1:8999/pl$n.mp4\" type=\"video/mp4\" length=\"1\"/></item>"
    done
    echo '</channel></rss>'
} > /tmp/www/feed.xml
N=$(videos alice | j 'count($d["videos"])')
PL="$DL/alice/Test playlist"
wpost alice /api/add '{"url": "http://127.0.0.1:8999/feed.xml", "kind": "video", "limit": 2}' > /dev/null
wait_videos alice $((N + 2)) && sleep 5 && [ "$(videos alice | j 'count($d["videos"])')" = $((N + 2)) ] && [ -f "$PL/001 - pl1 [playlist001].mp4" ] && [ -f "$PL/002 - pl2 [playlist002].mp4" ] && [ ! -e "$PL/003 - pl3 [playlist003].mp4" ] \
    && pass "limited to its first 2, in a folder of its own, numbered in its order" || fail "limit: $(ls "$PL")"
V=$(videos alice | j 'array_values(array_filter($d["videos"], function ($v) { return $v["playlist"] === "Test playlist"; }))')
[ "$(echo "$V" | j '(function ($l) { sort($l); return $l; })(array_map(function ($v) { return $v["index"] . ":" . $v["title"]; }, $d))' | tr -d '"[]')" = '1:pl1,2:pl2' ] \
    && pass 'the page knows each one'"'"'s playlist and position (titles without the number or ID - here, the files'"'"' own names)' || fail "playlist fields: $V"
wpost alice /api/keep '{"file": "Test playlist/002 - pl2 [playlist002].mp4", "keep": true}' > /dev/null
# (what yt-dlp leaves beside a playlist's videos: its own thumbnail)
cp "$PL/001 - pl1 [playlist001].mp4" "$PL/Test playlist.jpg"; chown metube "$PL/Test playlist.jpg"
[ "$(wpost bob /api/delete-playlist '{"playlist": "Test playlist"}')" = 'No such playlist' ] && [ "$(wpost alice /api/delete-playlist '{"playlist": ".."}')" = 'No such playlist' ] \
    && pass "not bob's, nor a way out of her folder" || fail 'delete-playlist not refused'
R=$(wpost alice /api/delete-playlist '{"playlist": "Test playlist"}')
[ "$(echo "$R" | j '$d["deleted"] . "/" . $d["kept"]')" = '"1/1"' ] && [ ! -e "$PL/001 - pl1 [playlist001].mp4" ] && [ -f "$PL/002 - pl2 [playlist002].mp4" ] \
    && pass 'Delete playlist: its videos deleted, the kept one not' || fail "delete playlist: $R $(ls "$PL")"
wpost alice /api/delete '{"file": "Test playlist/002 - pl2 [playlist002].mp4"}' > /dev/null
[ ! -d "$PL" ] && [ "$(videos alice | j 'in_array("Test playlist", $d["playlists"])')" = false ] \
    && pass "its last video deleted: the downloaded playlist's folder too (with the thumbnail yt-dlp left in it)" || fail "folder left: $(ls -la "$PL")"

echo "== a person's own playlists"
[ "$(wpost alice /api/new-playlist '{"name": "Holiday clips"}' | j '$d["name"]')" = '"Holiday clips"' ] && [ -d "$DL/alice/Holiday clips" ] \
    && [ "$(stat -c '%U %a' "$DL/alice/Holiday clips")" = 'metube 2775' ] && [ "$(videos alice | j 'in_array("Holiday clips", $d["playlists"])')" = true ] \
    && pass 'New playlist: its folder made, listed (empty)' || fail "new playlist: $(ls -la "$DL/alice")"
[ "$(wpost alice /api/new-playlist '{"name": "Holiday clips"}' | head -c 13)" = "There's alrea" ] && [ "$(wpost alice /api/new-playlist '{"name": "a/b"}' | head -c 14)" = 'Playlist names' ] \
    && [ "$(wpost alice /api/new-playlist '{"name": ".x"}' | head -c 14)" = 'Playlist names' ] && pass 'the same name twice, a slash or a leading dot refused' || fail 'bad playlist names'
wpost alice /api/add '{"url": "http://127.0.0.1:8999/pl3.mp4", "kind": "video", "playlist": "Holiday clips"}' > /dev/null
i=0; while [ $i -lt 60 ] && [ ! -f "$DL/alice/Holiday clips/pl3 [pl3].mp4" ]; do sleep 2; i=$((i + 2)); done
[ "$(videos alice | j 'array_values(array_filter($d["videos"], function ($v) { return $v["playlist"] === "Holiday clips"; }))[0]["title"]')" = '"pl3"' ] \
    && pass 'a download made while it was open went into it' || fail "into playlist: $(ls "$DL/alice/Holiday clips") $(videos alice | head -c 1500)"
wpost alice /api/delete '{"file": "Holiday clips/pl3 [pl3].mp4"}' > /dev/null
[ -d "$DL/alice/Holiday clips" ] && [ "$(videos alice | j 'in_array("Holiday clips", $d["playlists"])')" = true ] \
    && pass 'her own playlist stays when its last video goes' || fail 'own playlist removed'
wpost alice /api/add '{"url": "http://127.0.0.1:8999/pl3.mp4", "kind": "video", "playlist": "Holiday clips"}' > /dev/null
i=0; while [ $i -lt 60 ] && [ ! -f "$DL/alice/Holiday clips/pl3 [pl3].mp4" ]; do sleep 2; i=$((i + 2)); done
[ "$(wpost bob /api/add '{"url": "http://127.0.0.1:8999/pl3.mp4", "kind": "video", "playlist": "Holiday clips"}')" = 'No such playlist' ] \
    && [ "$(wpost alice /api/add '{"url": "http://127.0.0.1:8999/pl3.mp4", "kind": "video", "playlist": "../bob"}')" = 'No such playlist' ] \
    && pass "not into another's (or out of her folder)" || fail 'add into another playlist'
wpost alice /api/new-playlist '{"name": "Empty one"}' > /dev/null
cp "/tmp/www/Test clip.mp4" "$DL/alice/Holiday clips/Holiday clips.jpg"
[ "$(wpost alice /api/delete-playlist '{"playlist": "Empty one"}' | j '$d["deleted"]')" = 0 ] && [ ! -d "$DL/alice/Empty one" ] \
    && [ "$(wpost alice /api/delete-playlist '{"playlist": "Holiday clips"}' | j '$d["deleted"]')" = 1 ] && [ ! -d "$DL/alice/Holiday clips" ] \
    && [ "$(videos alice | j 'array_values(array_intersect(["Empty one", "Holiday clips"], $d["playlists"]))')" = '[]' ] \
    && pass 'Delete playlist: an empty one, and one with a video (and a leftover) - gone, folders and all' || fail "delete: $(ls -la "$DL/alice" "$DL/alice/Holiday clips")"
R=$(cd $P/metube/watch && $PY -c 'import watch; print(watch.plain_error("ERROR: [youtube] 8GOeT5O4nDk: The uploader has not made this video available in your country") + "|" + watch.plain_error("ERROR: [youtube] -So9lXFt5rM: Video unavailable. This video is not available"))')
[ "$R" = 'Not available in this country|Removed or unavailable on YouTube' ] && pass "YouTube's refusals in plain words: $R" || fail "plain errors: $R"

echo '== renaming'
A="abcdefghijk [abcdefghijk]"
cp "/tmp/www/Test clip.mp4" "$DL/alice/$A.jpg"; chown metube "$DL/alice/$A.jpg"
wpost alice /api/keep "{\"file\": \"$A.mp4\", \"keep\": true}" > /dev/null
[ "$(wpost alice /api/rename "{\"file\": \"$A.mp4\", \"title\": \"Bad: name\"}" | head -c 6)" = 'Titles' ] && [ "$(wpost bob /api/rename "{\"file\": \"$A.mp4\", \"title\": \"Mine\"}")" = 'No such video' ] \
    && pass "a title with : refused; not bob's to rename" || fail 'bad rename accepted'
R=$(wpost alice /api/rename "{\"file\": \"$A.mp4\", \"title\": \"  A  better   title \"}")
V=$(videos alice | j 'array_values(array_filter($d["videos"], function ($v) { return $v["video_id"] === "abcdefghijk"; }))[0]')
[ "$(echo "$R" | j '$d["file"]')" = '"A better title [abcdefghijk].mp4"' ] && [ -f "$DL/alice/A better title [abcdefghijk].jpg" ] && [ ! -e "$DL/alice/$A.mp4" ] \
    && [ "$(echo "$V" | j '$d["title"] . "|" . json_encode($d["kept"]) . "|" . $d["thumbnail"]')" = '"A better title|true|A better title [abcdefghijk].jpg"' ] \
    && pass 'renamed: the title only (its ID kept), its thumbnail with it, still kept' || fail "rename: $R $V"
mkdir -p "$DL/alice/Feed"; cp "/tmp/www/Test clip.mp4" "$DL/alice/Feed/002 - Old name [playlist002].mp4"; chown -R metube "$DL/alice/Feed"
R=$(wpost alice /api/rename '{"file": "Feed/002 - Old name [playlist002].mp4", "title": "New name"}')
[ "$(echo "$R" | j '$d["file"]')" = '"Feed/002 - New name [playlist002].mp4"' ] && pass "a playlist's video: its number kept" || fail "rename in playlist: $R"
wpost alice /api/new-playlist '{"name": "Summer"}' > /dev/null
[ "$(wpost alice /api/rename-playlist '{"playlist": "Feed", "name": "Summer"}' | head -c 13)" = "There's alrea" ] \
    && [ "$(wpost alice /api/rename-playlist '{"playlist": "Feed", "name": "a/b"}' | head -c 14)" = 'Playlist names' ] \
    && pass 'a playlist renamed onto another, or with a slash, refused' || fail 'bad playlist rename'
wpost alice /api/keep '{"file": "Feed/002 - New name [playlist002].mp4", "keep": true}' > /dev/null
R=$(wpost alice /api/rename-playlist '{"playlist": "Feed", "name": "Road trip 2026"}')
[ "$(echo "$R" | j '$d["name"]')" = '"Road trip 2026"' ] && [ -f "$DL/alice/Road trip 2026/002 - New name [playlist002].mp4" ] && [ ! -d "$DL/alice/Feed" ] \
    && [ "$(videos alice | j 'array_values(array_filter($d["videos"], function ($v) { return $v["playlist"] === "Road trip 2026"; }))[0]["kept"]')" = true ] \
    && pass 'a playlist renamed: its folder, its videos still kept' || fail "rename playlist: $R"
wpost alice /api/rename-playlist '{"playlist": "Summer", "name": "Winter"}' > /dev/null
[ "$(videos alice | j 'in_array("Winter", $d["playlists"]) && !in_array("Summer", $d["playlists"])')" = true ] && grep -q '"Winter"' $D/watch/alice.json \
    && pass 'her own playlist renamed: still hers (kept when empty)' || fail "own rename: $(cat $D/watch/alice.json)"
for pl in "Road trip 2026" Winter; do wpost alice /api/delete-playlist "{\"playlist\": \"$pl\"}" > /dev/null; done
wpost alice /api/delete-playlist '{"playlist": "Road trip 2026"}' > /dev/null

echo '== yt-dlp updates'
mkdir -p /tmp/index-broken /tmp/index-good
$PY /t/app/stubs.py index /tmp/index-broken 2099.1.1 broken; $PY /t/app/stubs.py index /tmp/index-good 2099.1.2
(cd /tmp/index-broken && $PY -m http.server 8996 --bind 127.0.0.1 > /dev/null 2>&1 &)
(cd /tmp/index-good && $PY -m http.server 8995 --bind 127.0.0.1 > /dev/null 2>&1 &)
wait_port 8996 10; wait_port 8995 10
YTDLP_INDEX_URL=http://127.0.0.1:8996/simple sh $P/metube/metube_ctl.sh ytdlp > /dev/null 2>&1
[ ! -d $D/ytdlp ] && grep -q 'failed: the new yt-dlp did not run (still 2026.10.26)' $D/ytdlp.status && [ "$(get status | j '$d["ytdlp"]')" = '"2026.10.26"' ] \
    && pass 'a broken yt-dlp refused: the packaged one still in use' || fail "broken: $(cat $D/ytdlp.status)"
post ytdlp_setting -d update= > /dev/null
YTDLP_INDEX_URL=http://127.0.0.1:8995/simple sh $P/metube/metube_ctl.sh ytdlp > /dev/null 2>&1
[ ! -d $D/ytdlp ] && pass 'turned off on the page: not updated at night' || fail 'updated while off'
YTDLP_INDEX_URL=http://127.0.0.1:8995/simple sh $P/metube/metube_ctl.sh ytdlp force > /dev/null 2>&1
[ "$(stat -c %U $D/ytdlp)" = metube ] && grep -q 'ok: 2099.1.2 (was 2026.10.26)' $D/ytdlp.status && [ "$(get status | j '$d["ytdlp"]')" = '"2099.1.2"' ] \
    && pass "\"Update now\": 2099.1.2 installed beside the packaged one, and used" || fail "update: $(cat $D/ytdlp.status)"
# (the stand-in can't download: back to the packaged one)
rm -rf $D/ytdlp; post ytdlp_setting -d update=1 > /dev/null

echo '== removing a person'
[ "$(post remove_user -d name=bob -d delete_videos=1 | j '$d["ok"]')" = true ] && [ "$(wcode bob /api/videos)" = 401 ] && [ ! -f $D/watch/bob.json ] \
    && pass "bob removed: logged out at once" || fail "remove: $(cat $D/users.json)"

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8086' $P/_nginx/sites/60-app-videos.conf 2>/dev/null && site /health | grep -q '"watch"' \
    && site / | grep -q '<title>Watch</title>' && pass "its site https://videos.$DOMAIN/ (the Watch page)" || fail "site: $(ls $P/_nginx/sites; site / | head -c 200)"

echo '== on the network'
RS=$(post listen -d listen=all)
[ "$(echo "$RS" | j '$d["ok"]')" = true ] && awk 'NR > 1 && $4 == "0A" && index($2, ":1F96") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && ! awk 'NR > 1 && $4 == "0A" && index($2, ":1F95") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && pass 'the Watch page on the network too (0.0.0.0:8086); MeTube still on the NAS only' || fail "listen all: $RS"
post listen -d listen=local > /dev/null
wait_port 8086 30 && pass 'and back' || fail 'listen local'

echo '== restart'
sh $P/metube/stop.sh $P/metube > /dev/null 2>&1
listening 8086 && fail 'still answering once stopped' || true
sh $P/metube/start.sh $P/metube > /tmp/start.log 2>&1
wait_port 8086 60 && login alice Alice.Pass-1 && [ "$(videos alice | j '$d["settings"]["watched_days"]')" = 1 ] \
    && pass "restarted: alice's login and settings kept" || fail "restart: $(tail -n 5 /tmp/start.log)"
grep -E 'Traceback|CRITICAL' $D/metube.log $D/watch.log | head -3

echo '== removal'
finish_app
! grep -q 'metube-daily\|metube-ytdlp' /var/spool/cron/crontabs/root && [ -d "$DL/alice" ] && [ -s $D/users.json ] \
    && pass 'its cron lines gone; the download folder and users kept' || fail 'removal'
