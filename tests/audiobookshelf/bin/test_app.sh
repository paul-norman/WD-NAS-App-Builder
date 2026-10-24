#!/bin/sh
# The app itself, on the NAS's glibc (2.31) with WD's shares: its user and first start (the root user claimed with a
# generated password), a library scanned (tags, chapters, cover, Unicode search), streaming to a player (transcoded to
# HLS), merging an audiobook into M4B, a podcast episode downloaded (ffmpeg over HTTP), a backup, a new password, stopping
A=/mnt/HD/HD_a2/Nas_Prog/audiobookshelf; D=/mnt/HD/HD_a2/Nas_Prog/_audiobookshelf; P=/mnt/HD/HD_a2/Public
U=http://127.0.0.1:13378
BOOK="$P/Audiobooks/Test Author/The Test Book"
. /t/bin/setup.sh
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
login() { curl -s -X POST -H 'Content-Type: application/json' -d "{\"username\":\"root\",\"password\":\"$1\"}" $U/login; }
api() { m=$1; p=$2; shift 2; curl -s -X $m -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@" "$U$p"; }
# Waits up to $1 seconds for a shell condition ($2)
until_true() { i=0; while [ $i -lt $1 ]; do eval "$2" && return 0; sleep 1; i=$((i + 1)); done; return 1; }

echo "== first start"
# (the test's podcast feed is on the NAS itself: allowed, as the page's setting would)
mkdir -p $D && printf 'LISTEN=all\nLOCAL_FEEDS=127.0.0.1\n' > $D/settings
sh $A/abs_ctl.sh start > /tmp/start.log 2>&1; cat /tmp/start.log
[ "$(id -u audiobookshelf)" = 83 ] && [ "$(id -gn audiobookshelf)" = share ] && pass "its own user (83), in the share group" || fail "user: $(id audiobookshelf)"
grep -q "on the NAS itself only, to create its root user" /tmp/start.log && grep -q "created the root user" /tmp/start.log \
	&& pass "first start: on 127.0.0.1 only until the app claimed the root user" || fail "claim: $(cat /tmp/start.log)"
curl -s $U/status | grep -q '"isInit":true' && pass "answering on 13378, set up (no setup page for the first visitor)" || { fail "status: $(curl -s $U/status)"; tail -n 30 $D/audiobookshelf.log; exit 1; }
PW=$(cat $D/root_password)
[ ${#PW} = 20 ] && [ "$(stat -c '%U %a' $D/root_password)" = "root 600" ] && [ "$(stat -c '%U %a' $D/config)" = "audiobookshelf 700" ] \
	&& pass "a generated root password (root's only); its database its user's only" || fail "files: $(ls -la $D)"
TOKEN=$(login "$PW" | j '$d["user"]["accessToken"]' | tr -d '"')
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] && pass "root logs in with it" || fail "login"
[ "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"root","password":""}' $U/login)" = 401 ] && pass "an empty password refused" || fail "empty password"

echo "== a library"
L=$(api POST /api/libraries -d "{\"name\":\"Audiobooks\",\"folders\":[{\"fullPath\":\"$P/Audiobooks\"}],\"mediaType\":\"book\"}" | j '$d["id"]' | tr -d '"')
api POST /api/libraries/$L/scan > /dev/null
until_true 60 '[ "$(api GET "/api/libraries/$L/items" | j "\$d[\"total\"]")" = 2 ]'
ITEM=$(api GET "/api/libraries/$L/items" | j 'array_values(array_filter($d["results"], function ($i) { return $i["media"]["metadata"]["title"] === "The Test Book"; }))[0] ?? null')
ID=$(echo "$ITEM" | j '$d["id"]' | tr -d '"')
echo "$ITEM" | grep -q '"title":"The Test Book"' && echo "$ITEM" | grep -q 'Test Author' && pass "scanned: The Test Book by Test Author" || fail "item: $(echo "$ITEM" | cut -c1-400)"
FULL=$(api GET "/api/items/$ID?expanded=1")
[ "$(echo "$FULL" | j 'count($d["media"]["audioFiles"])')" = 2 ] && [ "$(echo "$FULL" | j 'round($d["media"]["duration"])')" = 40 ] \
	&& pass "2 chapters, 40 seconds (ffprobe)" || fail "audio files: $(echo "$FULL" | j '[count($d["media"]["audioFiles"] ?? []), $d["media"]["duration"] ?? null]')"
curl -s -o /tmp/cover -H "Authorization: Bearer $TOKEN" "$U/api/items/$ID/cover"
[ "$(head -c 3 /tmp/cover | od -An -tx1 | tr -d ' ')" = ffd8ff ] || [ "$(head -c 4 /tmp/cover | tail -c 3)" = PNG ] || [ "$(head -c 4 /tmp/cover)" = RIFF ] \
	&& pass "its cover, from the files' embedded art ($(stat -c %s /tmp/cover) bytes)" || fail "cover: $(head -c 100 /tmp/cover)"
api GET "/api/libraries/$L/search?q=cafe" | grep -q 'Café Stories' && pass "search ignores accents: \"cafe\" finds Café Stories (SQLite's Unicode extension)" || \
	fail "search: $(api GET "/api/libraries/$L/search?q=cafe" | cut -c1-300)"

echo "== playing (transcoded for a player)"
S=$(api POST "/api/items/$ID/play" -d '{"deviceInfo":{"clientName":"test"},"forceTranscode":true,"supportedMimeTypes":[]}')
URL=$(echo "$S" | j '$d["audioTracks"][0]["contentUrl"]' | tr -d '"' | sed 's#\\/#/#g')
until_true 30 'curl -s -H "Authorization: Bearer $TOKEN" "$U$URL" | grep -q "#EXTINF"'
SEG=$(curl -s -H "Authorization: Bearer $TOKEN" "$U$URL" | grep -v '^#' | head -n 1)
DIR=$(dirname "$URL")
until_true 30 '[ "$(curl -s -o /tmp/seg -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$U$DIR/$SEG")" = 200 ] && [ "$(stat -c %s /tmp/seg)" -gt 10000 ]'
[ "$(stat -c %s /tmp/seg 2>/dev/null || echo 0)" -gt 10000 ] && pass "an HLS stream: $URL, first segment $SEG ($(stat -c %s /tmp/seg) bytes)" || fail "stream: $S"
api POST "/api/session/$(echo "$S" | j '$d["id"]' | tr -d '"')/close" -d '{}' > /dev/null

echo "== merging into M4B"
api POST "/api/tools/item/$ID/encode-m4b" -d '{}' > /dev/null
until_true 120 '[ -n "$(find "$BOOK" -name "*.m4b")" ]'
M4B=$(find "$BOOK" -name '*.m4b' | head -n 1)
# (it takes the first original track's place - and its owner and permissions)
[ -n "$M4B" ] && [ "$(head -c 8 "$M4B" | tail -c 4)" = ftyp ] && [ "$(stat -c %s "$M4B")" -gt 100000 ] \
	&& pass "an M4B made in the book's folder: $(basename "$M4B") ($(stat -c %s "$M4B") bytes)" || fail "m4b: $(ls -la "$BOOK"); $(tail -n 5 $D/audiobookshelf.log)"

echo "== a podcast (episodes downloaded by ffmpeg)"
PL=$(api POST /api/libraries -d "{\"name\":\"Podcasts\",\"folders\":[{\"fullPath\":\"$P/Podcasts\"}],\"mediaType\":\"podcast\"}")
PLID=$(echo "$PL" | j '$d["id"]' | tr -d '"'); FOLDER=$(echo "$PL" | j '$d["folders"][0]["id"]' | tr -d '"')
FEED=$(api POST /api/podcasts/feed -d '{"rssFeed":"http://127.0.0.1:8099/rss.xml"}')
echo "$FEED" | grep -q 'Episode One' && pass "the feed read" || fail "feed: $(echo "$FEED" | cut -c1-300)"
POD=$(api POST /api/podcasts -d "{\"path\":\"$P/Podcasts/Test Podcast\",\"folderId\":\"$FOLDER\",\"libraryId\":\"$PLID\",\"media\":{\"metadata\":{\"title\":\"Test Podcast\",\"feedUrl\":\"http://127.0.0.1:8099/rss.xml\"},\"autoDownloadEpisodes\":false}}")
PID=$(echo "$POD" | j '$d["id"]' | tr -d '"')
echo "$FEED" | j '$d["podcast"]["episodes"]' > /tmp/episodes.json
api POST "/api/podcasts/$PID/download-episodes" --data-binary @/tmp/episodes.json > /dev/null
until_true 60 '[ -n "$(find "$P/Podcasts/Test Podcast" -name "*.mp3" 2>/dev/null)" ]'
EP=$(find "$P/Podcasts/Test Podcast" -name '*.mp3' | head -n 1)
[ -n "$EP" ] && [ "$(stat -c %s "$EP")" -gt 10000 ] && grep -q 'episode1.mp3' /tmp/feed.log \
	&& [ "$(stat -c '%U:%G %a' "$EP")" = "audiobookshelf:share 664" ] \
	&& pass "an episode downloaded: $(basename "$EP"), changeable over SMB (audiobookshelf:share 664)" || fail "episode: $(ls -la "$P/Podcasts" "$P/Podcasts/Test Podcast" 2>&1); $(grep -i podcast $D/audiobookshelf.log | tail -n 5)"

echo "== a backup, a new password, stopping"
api POST /api/backups -d '{}' > /dev/null
until_true 30 '[ -n "$(find $D/metadata/backups -name "*.audiobookshelf" 2>/dev/null)" ]' && pass "a backup of its database: $(ls $D/metadata/backups)" || fail "backup: $(ls -R $D/metadata | head)"
sh $A/abs_ctl.sh new-password > /dev/null; PW2=$(cat $D/root_password)
[ "$PW2" != "$PW" ] && [ "$(code -X POST -H 'Content-Type: application/json' -d "{\"username\":\"root\",\"password\":\"$PW2\"}" $U/login)" = 200 ] \
	&& [ "$(code -X POST -H 'Content-Type: application/json' -d "{\"username\":\"root\",\"password\":\"$PW\"}" $U/login)" = 401 ] \
	&& pass "a new password works, the old one doesn't" || fail "new password"
sh $A/abs_ctl.sh stop > /dev/null; sleep 1
[ "$(ps | grep -c '[d]ist-server/index.js')" = 0 ] && pass "stopped" || fail "still running"
sh $A/abs_ctl.sh start > /dev/null 2>&1
[ "$(cat $D/root_password)" = "$PW2" ] && ! grep -q "for the first time" $D/audiobookshelf.log.restart 2>/dev/null && curl -s $U/status | grep -q '"isInit":true' \
	&& pass "started again: the same root user and password" || fail "restart"
