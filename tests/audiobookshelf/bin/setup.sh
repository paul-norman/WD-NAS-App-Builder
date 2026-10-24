#!/bin/sh
# Shared by the tests: a stand-in for the NAS - the app's files where the NAS installs it (when given in /app; its binaries
# are mounted at binaries/), BusyBox's user tools (the image's own BusyBox has no adduser), WD's shares (0777, root's, and
# the share group every NAS user is in), and something to listen to, made with the app's own ffmpeg: an audiobook (two
# tagged MP3 chapters with a cover), another with an accented title, and a podcast feed with one episode, served on port
# 8099
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in adduser addgroup ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:$PATH
grep -q '^share:' /etc/group || echo 'share:x:1000:' >> /etc/group
P=/mnt/HD/HD_a2/Public
BOOK="$P/Audiobooks/Test Author/The Test Book"
mkdir -p /mnt/HD/HD_a2/Nas_Prog "$BOOK" "$P/Audiobooks/Test Author/Café Stories" "$P/Podcasts" /tmp/feed
chmod 777 /mnt/HD/HD_a2/Nas_Prog $P
[ -d /app ] && mkdir -p /mnt/HD/HD_a2/Nas_Prog/audiobookshelf && cp -r /app/. /mnt/HD/HD_a2/Nas_Prog/audiobookshelf/
B=/mnt/HD/HD_a2/Nas_Prog/audiobookshelf/binaries
if [ -x $B/ffmpeg ]; then
	python3 - <<'PY'
import math, struct, wave, zlib
for name, freq in (("/tmp/one.wav", 440), ("/tmp/two.wav", 550), ("/tmp/ep.wav", 660)):
    w = wave.open(name, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(i * freq * 2 * math.pi / 22050))) for i in range(22050 * 20)))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
row = b"\x00" + bytes((40, 90, 160)) * 300
open("/tmp/cover.png", "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 300, 300, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(row * 300, 9)) + chunk(b"IEND", b""))
PY
	$B/ffmpeg -v error -y -i /tmp/cover.png /tmp/cover.jpg
	n=1
	for part in one two; do
		$B/ffmpeg -v error -y -i /tmp/$part.wav -i /tmp/cover.jpg -map 0 -map 1 -c:a libmp3lame -b:a 64k -c:v copy -id3v2_version 3 \
			-disposition:v attached_pic -metadata album="The Test Book" -metadata artist="Test Author" -metadata title="Chapter $n" \
			-metadata track=$n "$BOOK/0$n Chapter $n.mp3"
		n=$((n + 1))
	done
	$B/ffmpeg -v error -y -i /tmp/two.wav -c:a libmp3lame -b:a 64k -metadata album="Café Stories" -metadata artist="Test Author" \
		"$P/Audiobooks/Test Author/Café Stories/01.mp3"
	$B/ffmpeg -v error -y -i /tmp/ep.wav -c:a libmp3lame -b:a 64k /tmp/feed/episode1.mp3
	size=$(stat -c %s /tmp/feed/episode1.mp3)
	cat > /tmp/feed/rss.xml <<RSS
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>Test Podcast</title><link>http://127.0.0.1:8099/</link><description>A test feed</description>
<itunes:author>Test Host</itunes:author>
<item><title>Episode One</title><guid>test-episode-1</guid><pubDate>Fri, 23 Oct 2026 10:00:00 +0000</pubDate>
<enclosure url="http://127.0.0.1:8099/episode1.mp3" length="${size}" type="audio/mpeg"/><itunes:duration>20</itunes:duration></item>
</channel></rss>
RSS
	(cd /tmp/feed && python3 -m http.server 8099 --bind 127.0.0.1 > /tmp/feed.log 2>&1 &)
	chmod -R a+rwX $P
fi
true
