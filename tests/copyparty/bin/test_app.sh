#!/bin/sh
# The app itself, on the NAS's glibc (2.31) with WD's shares (0777, root's): its user and first start, logins (hashed
# passwords only in its configuration), uploads into a share (writable by the share group, nothing of its own left in
# the shares), thumbnails (JPEG, HEIC, video, audio) and transcoding, search, access levels, everyone without a login,
# symbolic links out of a folder, SFTP, nothing shared, stopping
A=/mnt/HD/HD_a2/Nas_Prog/copyparty; D=/mnt/HD/HD_a2/Nas_Prog/_copyparty; P=/mnt/HD/HD_a2/Public; B=$A/binaries
U=http://127.0.0.1:3923
. /t/bin/setup.sh
PY=$B/python/bin/python3
# The settings as the management page changes them: $1 a Python expression run on s (the settings)
settings() { $PY -c "import json; f='$D/settings.json'; s=json.load(open(f)); $1; json.dump(s, open(f, 'w'))"; }
pw() { $PY -c "import json; print([u['password'] for u in json.load(open('$D/settings.json'))['users'] if u['name'] == '$1'][0])"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# (as a browser: copyparty answers curl with plain text)
json() { curl -s -A 'Mozilla/5.0' "$@"; }

echo "== first start"
sh $A/cpp_ctl.sh start > /tmp/start.log 2>&1; cat /tmp/start.log
[ "$(id -u copyparty)" = 81 ] && [ "$(id -gn copyparty)" = share ] && pass "its own user (81), in the share group" || fail "user: $(id copyparty)"
[ "$(code $U/)" = 200 ] && pass "answering on 3923" || { fail "not answering"; tail -30 $D/copyparty.log; exit 1; }
PW=$(pw admin)
[ ${#PW} = 20 ] && [ "$(stat -c '%U %a' $D/settings.json)" = "root 600" ] && pass "an admin user with a generated password (settings: root's only)" || fail "settings: $(ls -l $D)"
grep -q "admin: +" $D/config/copyparty.conf && ! grep -q "$PW" $D/config/copyparty.conf && [ "$(stat -c '%U %a' $D/config/copyparty.conf)" = "copyparty 600" ] \
	&& pass "its configuration holds the password's hash only (its user's only)" || fail "config: $(cat $D/config/copyparty.conf)"

echo "== logins"
[ "$(code -u admin:$PW $U/public/?ls)" = 200 ] && pass "admin logs in to the Public share" || fail "login"
[ "$(code -u admin:wrong $U/public/?ls)" = 403 ] && [ "$(code $U/public/?ls)" = 403 ] && pass "a wrong password, or none: refused" || fail "no login allowed"
[ "$(code -u $PW:x $U/public/?ls)" = 403 ] && pass "the password alone (copyparty's default) isn't enough: user names required" || fail "password-only login"

echo "== uploads"
echo hello > /tmp/h.txt
[ "$(code -u admin:$PW -T /tmp/h.txt "$U/public/New%20folder/h.txt")" = 201 ] && [ "$(cat "$P/New folder/h.txt")" = hello ] && pass "uploaded into a new folder" || fail "upload"
[ "$(stat -c '%U:%G %a' "$P/New folder" "$P/New folder/h.txt" | tr '\n' ' ')" = "copyparty:share 775 copyparty:share 664 " ] \
	&& pass "owned by copyparty, writable by the share group (so changeable over SMB)" || fail "owners: $(ls -la "$P/New folder")"
[ -z "$(find $P -name '.hist')" ] && [ -f $D/hist/*/up2k.db ] && pass "its database stays with the app, not in the share" || fail "hist: $(find $P $D/hist)"

echo "== thumbnails and transcoding"
$PY -c "
from PIL import Image; import pillow_heif; pillow_heif.register_heif_opener()
im = Image.new('RGB', (800, 600), (200, 50, 50)); im.save('$P/pic.jpg'); im.save('$P/pic.heic')
import wave, math, struct
w = wave.open('/tmp/tone.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<h', int(8000 * math.sin(i * 440 * 2 * math.pi / 44100))) for i in range(44100 * 3)))"
$B/ffmpeg -v error -y -loop 1 -i $P/pic.jpg -t 2 -r 10 -c:v mpeg4 $P/clip.mp4
$B/ffmpeg -v error -y -i /tmp/tone.wav -metadata artist="Test Artist" -metadata title="Test Tone" $P/tone.flac
for f in pic.jpg pic.heic clip.mp4 tone.flac; do
	curl -s -u admin:$PW -o /tmp/th "$U/public/$f?th=w"
	[ "$(head -c 4 /tmp/th)" = RIFF ] && pass "thumbnail of $f (WebP)" || fail "thumbnail of $f: $(head -c 200 /tmp/th)"
done
curl -s -u admin:$PW -o /tmp/a.opus "$U/public/tone.flac?th=opus"
[ "$(head -c 4 /tmp/a.opus)" = OggS ] && pass "FLAC transcoded to Opus for its player" || fail "transcoding: $(head -c 200 /tmp/a.opus)"

echo "== search (file names, found at start), music tags (when turned on)"
settings "s['tags'] = True"
sh $A/cpp_ctl.sh restart > /dev/null 2>&1; sleep 3
R=$(json -u admin:$PW -X POST -d '{"q":"name like *tone*"}' "$U/public/?srch")
echo "$R" | grep -q 'tone.flac' && pass "search finds a file copied in by other means" || fail "search: $(echo "$R" | head -c 300)"
echo "$R" | grep -q 'Test Artist' && pass "with its music tags" || fail "tags: $(echo "$R" | head -c 300)"

echo "== access levels, everyone without a login, symbolic links"
settings "s['users'].append({'name': 'viewer', 'password': 'Viewer-pass-123', 'hash': ''}); s['users'].append({'name': 'dropper', 'password': 'Dropper-pass-123', 'hash': ''}); s['folders'][0]['access'].update({'viewer': 'read', 'dropper': 'upload'}); s['folders'].append({'name': 'family', 'path': '/mnt/HD/HD_a2/Family', 'access': {'*': 'read'}})"
echo family > /mnt/HD/HD_a2/Family/f.txt; ln -sf /etc /mnt/HD/HD_a2/Family/etc
sh $A/cpp_ctl.sh restart > /dev/null 2>&1
[ "$(code -u viewer:Viewer-pass-123 $U/public/?ls)" = 200 ] && [ "$(code -u viewer:Viewer-pass-123 -T /tmp/h.txt $U/public/v.txt)" != 201 ] \
	&& pass "view: can list, can't upload" || fail "viewer"
[ "$(code -u dropper:Dropper-pass-123 -T /tmp/h.txt $U/public/d.txt)" = 201 ] && ! json -u dropper:Dropper-pass-123 "$U/public/?ls" | grep -q 'pic.jpg' \
	&& pass "upload only: can upload, can't see what's there" || fail "dropper: $(json -u dropper:Dropper-pass-123 "$U/public/?ls" | head -c 300)"
[ "$(curl -s $U/family/f.txt)" = family ] && [ "$(code -T /tmp/h.txt $U/family/x.txt)" != 201 ] && pass "everyone without a login: read only, as set" || fail "anonymous"
[ "$(code $U/family/etc/passwd)" != 200 ] && ! curl -s $U/family/etc/passwd | grep -q 'root:' && pass "a symbolic link out of the folder isn't followed ($(code $U/family/etc/passwd))" || fail "symlink: $(curl -s $U/family/etc/passwd | head -c 100)"

echo "== SFTP"
settings "s['sftp'] = True"
sh $A/cpp_ctl.sh restart > /dev/null 2>&1; sleep 2
cat > /tmp/sftp.py <<EOF
import paramiko
t = paramiko.Transport(("127.0.0.1", 3922)); t.connect(username="admin", password="$PW")
print(sorted(paramiko.SFTPClient.from_transport(t).listdir("/public")))
EOF
R=$($PY /tmp/sftp.py 2>&1 | tail -1)
echo "$R" | grep -q "tone.flac" && pass "SFTP with the same user name and password: $R" || fail "SFTP: $R"
[ -f $D/config/copyparty/ssh_host_ed25519_key ] || [ -n "$(ls $D/config/copyparty/ 2>/dev/null | grep -i host)" ] && pass "its host keys kept with its data: $(ls $D/config/copyparty | grep -i host | tr '\n' ' ')" || fail "host keys: $(ls -R $D/config)"

echo "== nothing shared"
settings "s['folders'] = []; s['sftp'] = False"
sh $A/cpp_ctl.sh restart > /dev/null 2>&1
L=$(json -u admin:$PW "$U/?ls")
C=$(curl -s -u admin:$PW $U/copyparty.conf)
! echo "$C" | grep -q 'global' && ! echo "$L" | grep -q 'copyparty.conf' && pass "an empty folder, not copyparty's own working folder ($(code -u admin:$PW $U/copyparty.conf))" || fail "nothing shared: $(echo "$L" | head -c 300)"

echo "== stopping"
sh $A/cpp_ctl.sh stop > /dev/null; sleep 1
[ "$(ps | grep -c '[m] copyparty')" = 0 ] && [ "$(code $U/)" = 000 ] && pass "stopped" || fail "still running"
