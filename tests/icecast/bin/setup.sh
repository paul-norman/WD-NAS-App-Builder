#!/bin/sh
# Shared by the tests: a stand-in for the NAS - the app's files where the NAS installs it (when given in /app; its
# binaries are mounted at binaries/), BusyBox's user tools and ip (the image's own BusyBox has no adduser; the NAS's ip
# is BusyBox's), WD's /dev/urandom (readable by root only), and some music: tagged MP3s and a WAV with an awkward name,
# made with the app's own ffmpeg
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in adduser addgroup ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
ln -sf /t/bb/busybox /sbin/ip
export PATH=/tmp/bb:$PATH
chmod 600 /dev/urandom /dev/random
M='/mnt/HD/HD_a2/Public/Shared Music'
mkdir -p /mnt/HD/HD_a2/Nas_Prog "$M/Band A" "$M/.hidden"
[ -d /app ] && mkdir -p /mnt/HD/HD_a2/Nas_Prog/icecast && cp -r /app/. /mnt/HD/HD_a2/Nas_Prog/icecast/
B=/mnt/HD/HD_a2/Nas_Prog/icecast/binaries

if [ -x $B/ffmpeg ]; then
    python3 - "$M" <<'PY'
import math, struct, sys, wave
for name, freq in (("/tmp/one.wav", 440), ("/tmp/two.wav", 550), (sys.argv[1] + "/Band A/It's a \"Tone\" & more.wav", 660)):
    w = wave.open(name, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b"".join(struct.pack("<hh", int(6000 * math.sin(i * freq * 2 * math.pi / 44100)), 0) for i in range(44100 * 30)))
PY
    $B/ffmpeg -v error -y -i /tmp/one.wav -c:a libmp3lame -b:a 96k -metadata artist='Test Artist' -metadata title='First Song' "$M/Band A/01 first.mp3"
    $B/ffmpeg -v error -y -i /tmp/two.wav -c:a libmp3lame -b:a 96k -metadata artist='Test Artist' -metadata title='Second Song' "$M/02 second.mp3"
    cp "$M/02 second.mp3" "$M/.hidden/not me.mp3"; echo notes > "$M/notes.txt"
    chmod -R a+rX /mnt/HD/HD_a2/Public
fi
true
