#!/bin/sh
# Music Assistant from its package (tests/common/nas.sh): its first start (the admin account claimed by the app before
# anyone on the network can, Smart Fades removed), the page's token and new passwords, a music folder on the NAS scanned
# with its own ffmpeg/ffprobe (tags read), backups (it's stopped for the copy, then started again), removal
. /t/common/nas.sh music-assistant
U=http://127.0.0.1:8095
# A command on its API with the page's token (or the token given as $3)
api() { curl -s -H "Authorization: Bearer ${3:-$(cat $D/page_token)}" -H 'Content-Type: application/json' \
    -d "{\"message_id\":\"t\",\"command\":\"$1\",\"args\":${2:-{\}}}" $U/api; }
login() { curl -s -H 'Content-Type: application/json' -d "{\"credentials\":{\"username\":\"admin\",\"password\":\"$1\"},\"device_name\":\"test\"}" $U/auth/login | j '$d["success"] ?? false'; }

# No certificate authorities in /etc/ssl, as on the NAS: Debian's would hide a Python that can't find its own
mkdir -p /tmp/ssl-hidden && mv /etc/ssl/certs /etc/ssl/cert.pem /tmp/ssl-hidden/ 2>/dev/null

echo '== first start'
install_app
wait_port 8095 240 && pass 'answering on 8095' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 $D/console.log)"; exit 1; }
page_up
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"2.10.11"' ] && [ "$(echo "$ST" | j '$d["has_admin"]')" = true ] && [ "$(echo "$ST" | j 'is_array($d["players"])')" = true ] \
    && pass 'the page: Music Assistant 2.10.11, its admin account, the players (with its own token)' || fail "status: $(echo "$ST" | head -c 300)"
[ "$(awk '/^Uid:/ { print $2 }' /proc/$(cat /var/run/music-assistant.pid)/status)" = 79 ] && [ "$(stat -c '%u %a' $D/data)" = '79 700' ] \
    && [ "$(stat -c '%u %a' $D/admin_password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/page_token)" = '0 600' ] \
    && pass "runs as its own user (79); the admin password and page token root's only" || fail "users: $(stat -c '%n %u %a' $D/data $D/admin_password $D/page_token)"

echo '== the admin account, claimed by the app'
PW=$(post password | j '$d["password"]' | tr -d '"')
R=$(curl -s -H "Content-Type: application/json" -d '{"username":"intruder","password":"Intruder-Passw0rd","device_name":"x"}' $U/setup)
[ "$(login "$PW")" = true ] && [ "$(login wrong)" != true ] && [ "$(echo "$R" | j '$d["success"] ?? false')" != true ] \
    && pass "the page's password logs in; nobody else can set it up: $(echo "$R" | head -c 80)" || fail "admin: $(login "$PW") $R"
api config/providers | grep -q '"domain":"smart_fades"' && fail 'Smart Fades still there' || pass 'the Smart Fades provider removed (it needs AVX2 and PyTorch, left out)'
PROVIDERS=$P/music-assistant/binaries/python/lib/python3.14/site-packages/music_assistant/providers
[ ! -d $PROVIDERS/smart_fades ] && [ ! -d $PROVIDERS/sonic_analysis ] && [ -d $PROVIDERS/filesystem_local ] && ! grep -q 'Failed to install package' $D/data/musicassistant.log \
    && pass "providers whose packages were left out aren't offered, so it never tries to install them" || fail "providers: $(grep "Failed to install" $D/data/musicassistant.log | head -n 2)"
echo "== HTTPS (e.g. the NAS's own Navidrome site, streaming services)"
MAPY=$P/music-assistant/binaries/python/bin/python3
HTTPS='import ssl, urllib.request; urllib.request.urlopen("https://www.python.org", timeout=20); print("verified")'
# What ma_ctl.sh starts it with - its environment can't be read here, it's another user's process
CA=$(sed -n 's|^CA_FILE="${BIN}/\(.*\)"$|\1|p' $P/music-assistant/ma_ctl.sh)
grep -q 'SSL_CERT_FILE="${CA_FILE}"' $P/music-assistant/ma_ctl.sh && [ -f "$P/music-assistant/binaries/$CA" ] && ENVIRON="SSL_CERT_FILE=$P/music-assistant/binaries/$CA"
! $MAPY -I -c "$HTTPS" > /dev/null 2>&1 && [ "$(env "$ENVIRON" $MAPY -c "$HTTPS" 2>&1)" = verified ] \
    && pass "its Python checks HTTPS certificates with the bundled authorities ($(basename "${ENVIRON#*=}")) - not without them, as on the NAS" \
    || fail "https: '$ENVIRON' $(env "$ENVIRON" $MAPY -c "$HTTPS" 2>&1 | tail -n 1)"

echo '== new password'
NP=$(post new_password | j '$d["password"]' | tr -d '"')
[ ${#NP} -ge 16 ] && [ "$NP" != "$PW" ] && [ "$(login "$NP")" = true ] && [ "$(login "$PW")" != true ] && [ "$(get status | j 'is_array($d["players"])')" = true ] \
    && pass "a new one works, the old one doesn't; the page still has a working token" || fail "new password: $NP $(login "$NP")"

echo '== a music folder'
mkdir -p $V/Music/Testers && chmod 755 $V/Music $V/Music/Testers
# 5 seconds of a 440 Hz tone, encoded and tagged with the app's ffmpeg - it has no lavfi to make one itself
php -r '$n = 44100 * 5; $d = ""; for ($i = 0; $i < $n; $i++) { $d .= pack("v", (int)(8000 * sin(2 * M_PI * 440 * $i / 44100)) & 0xffff); }
	echo "RIFF" . pack("V", 36 + 2 * $n) . "WAVEfmt " . pack("VvvVVvv", 16, 1, 1, 44100, 88200, 2, 16) . "data" . pack("V", 2 * $n) . $d;' > /tmp/tone.wav
$P/music-assistant/binaries/ffmpeg -hide_banner -loglevel error -i /tmp/tone.wav -metadata title='Stand-in Song' \
    -metadata artist='The Testers' -metadata album='On the NAS' $V/Music/Testers/song.flac && chmod 644 $V/Music/Testers/song.flac
FLOW=$(api config/providers/setup '{"provider_domain":"filesystem_local"}' | j '$d["flow_id"]')
R=$(api config/flows/submit "{\"flow_id\":$FLOW,\"values\":{\"content_type\":\"music\",\"path\":\"$V/Music\"}}")
echo "$R" | grep -q '"type":"finish"' || fail "folder not added: $(echo "$R" | head -c 300)"
api music/sync > /dev/null; i=0

while [ $i -lt 60 ] && ! api music/tracks/library_items | grep -q 'Stand-in Song'; do sleep 2; i=$((i + 1)); done
LIB=$(api music/tracks/library_items)
echo "$LIB" | grep -q 'Stand-in Song' && echo "$LIB" | grep -q 'The Testers' && echo "$LIB" | grep -q '"duration":5' \
    && pass 'a music folder on the NAS scanned: the track, its artist and length read with its own ffprobe' || fail "library: $(echo "$LIB" | head -c 300) $(grep -i error $D/data/musicassistant.log | tail -n 3)"

echo '== backups'
OLD=$(cat /var/run/music-assistant.pid)
R1=$(post backup); sleep 1; R2=$(post backup)
set -- $D/backups/music-assistant-*.tar.gz; B="$1"
mkdir -p /tmp/restore && tar -xzf "$B" -C /tmp/restore
wait_port 8095 120; sleep 2
[ "$(stat -c '%a' "$B")" = 600 ] && ls /tmp/restore/data | grep -q '\.db$' && [ "$(cat /var/run/music-assistant.pid)" != "$OLD" ] \
    && api music/tracks/library_items | grep -q 'Stand-in Song' && pass "backed up ($(ls /tmp/restore/data | tr '\n' ' ' | cut -c1-60)): stopped for the copy, started again with its library" \
    || fail "backup: $R1 $R2 $(ls -l $D/backups) $(tail -n 3 /tmp/debug_apkg)"

echo '== removed'
finish_app
