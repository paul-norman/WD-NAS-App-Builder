#!/bin/sh
# Navidrome from its package (tests/common/nas.sh): its first start (an admin user with a generated password - not the
# throwaway one it starts with), a music folder scanned (tagged MP3s, made with the app's own ffmpeg), streaming
# transcoded to Opus, its page (status, password, settings and their checks, scans), stopping and removal
. /t/common/nas.sh navidrome
U=http://127.0.0.1:4533; M="$V/Public/Shared Music"
mkdir -p "$M/Test Artist/Test Album"
python3 -c "
import math, struct, wave
for n, f in ((1, 440), (2, 550)):
    w = wave.open('/tmp/%d.wav' % n, 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b''.join(struct.pack('<h', int(6000 * math.sin(i * f * 2 * math.pi / 22050))) for i in range(22050 * 10)))"

echo '== first start'
install_app
B=$P/navidrome/binaries

for n in 1 2; do $B/ffmpeg -v error -y -i /tmp/$n.wav -c:a libmp3lame -b:a 96k -metadata artist='Test Artist' -metadata album='Test Album' \
    -metadata title="Song $n" -metadata track=$n "$M/Test Artist/Test Album/0$n Song $n.mp3"; done
chmod -R a+rX "$V/Public"
wait_port 4533 60 && pass 'answering on 4533' || { fail "not answering: $(tail -n 10 /tmp/start.log $D/navidrome.log)"; exit 1; }
PW=$(cat $D/admin_password)
login() { curl -s -X POST -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$1\"}" $U/auth/login; }
[ ${#PW} = 20 ] && [ "$(stat -c '%U %a' $D/admin_password)" = 'root 600' ] && login "$PW" | grep -q '"token"' \
    && pass "admin logs in with the app's generated password (root's only)" || fail "login: $(login "$PW" | head -c 200)"
! grep -q "DEVAUTOCREATEADMINPASSWORD\|$PW" $D/navidrome.log && pass 'its log holds neither the throwaway first password nor the real one' || fail 'password in the log'
grep -q '^MusicFolder = "/mnt/HD/HD_a2/Public/Shared Music"' $D/data/navidrome.toml && grep -q '^EnableInsightsCollector = false' $D/data/navidrome.toml \
    && pass "its configuration: WD's Shared Music folder, no usage statistics sent" || fail "config: $(head -n 12 $D/data/navidrome.toml)"

echo '== the page, a scan, streaming'
page_up
post scan -d full=1 > /dev/null

for i in $(seq 1 30); do [ "$(get status | j '$d["libraries"][0]["songs"] ?? 0')" = 2 ] && break; sleep 2; done
ST=$(get status)
[ "$(echo "$ST" | j '$d["libraries"][0]["songs"]')" = 2 ] && [ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["music_readable"]')" = true ] \
    && pass "scanned through the page: $(echo "$ST" | j '$d["libraries"][0]["songs"]') songs, $(echo "$ST" | j '$d["libraries"][0]["albums"]') album" || fail "scan: $(echo "$ST" | j '$d["libraries"] ?? $d')"
S="u=admin&p=$PW&v=1.16.1&c=test&f=json"
ID=$(curl -s "$U/rest/search3.view?$S&query=Song" | j '$d["subsonic-response"]["searchResult3"]["song"][0]["id"]' | tr -d '"')
curl -s -o /tmp/s.opus "$U/rest/stream.view?$S&id=$ID&format=opus&maxBitRate=64"
[ "$(head -c 4 /tmp/s.opus)" = OggS ] && pass "streamed to a Subsonic app as Opus (the app's ffmpeg transcoding): $(stat -c %s /tmp/s.opus) bytes" || fail "stream: $(head -c 200 /tmp/s.opus)"
[ "$(post password -d show=1 | j '$d["password"]' | tr -d '"')" = "$PW" ] && pass 'the page shows the password' || fail 'password'
NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"')
[ "$NEW" != "$PW" ] && login "$NEW" | grep -q '"token"' && ! login "$PW" | grep -q '"token"' && pass "a new password works, the old one doesn't" || fail 'new password'

echo '== settings'
settings() { post settings --data-urlencode "music_folder=$1" -d listen="${2:-all}" -d external="${3:-0}"; }
settings '/mnt/HD/HD_a2/Public/bad"quote' | grep -q 'music folder must be' ; R2=$?
settings "$V/Public/missing" | grep -q 'No such folder'; R3=$?
mkdir -p $V/Public/Private && chmod 700 $V/Public/Private
settings "$V/Public/Private" | grep -q "can't read"; R4=$?
[ $R2 = 0 ] && [ $R3 = 0 ] && [ $R4 = 0 ] && pass "refused: a quote in the folder (it goes into a TOML file), a missing folder, one it can't read" || fail "checks: $R2 $R3 $R4"
settings "$M" local 1 > /dev/null; wait_port 4533 30
grep -q '^Address = "127.0.0.1"' $D/data/navidrome.toml && grep -q '^EnableExternalServices = true' $D/data/navidrome.toml && login "$NEW" | grep -q '"token"' \
    && pass 'only through the Nginx app (127.0.0.1), artist images on - restarted, users kept' || fail "settings: $(grep -E '^(Address|EnableExternal)' $D/data/navidrome.toml)"

echo '== removed'
finish_app
