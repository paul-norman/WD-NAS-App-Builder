#!/bin/sh
# The app itself, on the NAS's glibc (2.31) with WD's restrictions (/dev/random and /dev/urandom readable by root only, no
# writable /dev/shm): the runtime is complete, first start, the ingest folder, Calibre-Web finding the bundled tools,
# conversions (through Calibre-Web, and to PDF - Chromium), covers of PDFs, a new password, backups, stopping
A=/mnt/HD/HD_a2/Nas_Prog/calibre-web; D=/mnt/HD/HD_a2/Nas_Prog/_calibre-web; P=/mnt/HD/HD_a2/Public; B=$A/binaries
L="$P/Books/Calibre Library"
. /t/bin/setup.sh
chmod 755 /dev/shm; chmod 600 /dev/urandom /dev/random

echo "== the runtime is complete (on the NAS's glibc, without Bookworm's libraries)"
find $B -path $B/runtime -prune -o -type f \( -name '*.so*' -o -perm -u+x \) -print > /tmp/files
# (Calibre's files with Calibre's library folders, as its launchers run them; the rest as they are. The loader stops at the
# first library it can't find: "error while loading shared libraries: <name>: ...")
CL=$(find $B/calibre -name '*.so*' -exec dirname {} \; | sort -u | tr '\n' ':')
while read -r f; do
	case "$f" in $B/calibre/*) lp="$CL" ;; *) lp="" ;; esac
	LD_LIBRARY_PATH="$lp" $B/runtime/ld-linux-x86-64.so.2 --list "$f" 2>&1 | sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p; s/^\s*\(\S*\) => not found.*/\1/p'
done < /tmp/files | grep -v / | sort -u > /tmp/missing
# (Calibre's parts that only its desktop programs use)
GUI='libQt6EglFSDeviceIntegration.so.6 libQt6EglFsKmsGbmSupport.so.6 libQt6EglFsKmsSupport.so.6 libQt6Pdf.so.6 libQt6PdfWidgets.so.6 libQt6SvgWidgets.so.6 libQt6Test.so.6 libQt6WlShellIntegration.so.6 libflite.so.1 libpulse.so.0 libspeechd.so.2'
UNEXPECTED=$(for m in $(cat /tmp/missing); do echo " $GUI " | grep -q " $m " || echo $m; done)
[ -z "$UNEXPECTED" ] && pass "every library resolves ($(wc -l < /tmp/files) files; only Calibre's GUI-only ones missing: $(wc -l < /tmp/missing))" || fail "missing: $UNEXPECTED"

echo "== first start"
sh $A/cw_ctl.sh start > /tmp/start.log 2>&1; cat /tmp/start.log
PW=$(cat $D/admin_password)
[ -f "$L/metadata.db" ] && pass "library created: $L" || fail "no library"
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/login)" = 200 ] && pass "answering on 8083" || { fail "not answering"; tail -30 $D/data/console.log; tail -20 $D/data/calibre-web.log; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" http://127.0.0.1:8083/opds)" = 200 ] && pass "admin logs in with the app's password (OPDS)" || fail "login: $(curl -s -u "admin:$PW" http://127.0.0.1:8083/opds | head -c 200)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u admin:admin123 http://127.0.0.1:8083/opds)" != 200 ] && pass "Calibre-Web's default password (admin123) refused" || fail "admin123 works"
[ "$(stat -c %A /dev/urandom | cut -c 8)" = r ] && pass "/dev/urandom made readable by all (Chromium needs it)" || fail "urandom: $(ls -l /dev/urandom)"

echo "== the ingest folder"
sed -i 's/^INGEST=0/INGEST=1/; s/^INGEST_CONVERT=none/INGEST_CONVERT=epub/' $D/settings
I="$P/Books/Add to library"; mkdir -p "$I"
cp /book/book.epub "$I/The Test Book.epub"; cp /book/book.epub "$I/fresh.epub"; echo junk > "$I/notes.xyz"
printf 'A Short Story\n\nIt was a dark and stormy night.\n' > "$I/story.txt"
touch -d '2 minutes ago' "$I/The Test Book.epub" "$I/story.txt" "$I/notes.xyz"
sh $A/cw_ctl.sh ingest; cat $D/ingest.log
[ -f "$I/Added/The Test Book.epub" ] && [ -f "$I/Added/story.txt" ] && [ -f "$I/Not added/notes.xyz.why.txt" ] && [ -f "$I/fresh.epub" ] \
	&& pass "books added, other files set aside with a note, a file changed in the last minute left for later" || fail "ingest: $(ls -R "$I")"
grep -q 'story.txt (book [0-9]*, with an EPUB made from it)' $D/ingest.log && pass "an EPUB made from the text file" || fail "no EPUB: $(cat $D/ingest.log)"
touch -d '2 minutes ago' "$I/fresh.epub"; sh $A/cw_ctl.sh ingest
grep -q "Already in the library" "$I/Not added/fresh.epub.why.txt" 2>/dev/null && pass "duplicate not added: $(cat "$I/Not added/fresh.epub.why.txt")" || fail "duplicate"
curl -s -u "admin:$PW" http://127.0.0.1:8083/opds/new | grep -q 'The Test Book' && pass "the ingested book is in Calibre-Web (OPDS), without a reconnect" || fail "not seen"

echo "== what Calibre-Web found (its About page)"
J=/tmp/cookies
curl -s -c $J -b $J http://127.0.0.1:8083/login > /tmp/l.html; T=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' /tmp/l.html | head -1)
curl -s -c $J -b $J -o /dev/null -d "csrf_token=$T&username=admin&password=$PW&remember_me=on&next=/" http://127.0.0.1:8083/login
curl -s -c $J -b $J http://127.0.0.1:8083/stats | tr -d '\n' | grep -o -E '<th>(Image Magick|Ebook converter|Kepubify)</th>\s*<td>[^<]*</td>' | sed 's/<[^>]*>/ /g' | tr -s ' ' > /tmp/found
grep -q '(calibre 9' /tmp/found && grep -q 'kepubify v4' /tmp/found && grep -q 'ImageMagick 6' /tmp/found && pass "Calibre-Web found the converter, kepubify and ImageMagick: $(tr '\n' ';' < /tmp/found)" || fail "About page: $(cat /tmp/found)"

echo "== conversion through Calibre-Web"
ID=$(curl -s -u "admin:$PW" http://127.0.0.1:8083/opds/new | grep -o '/opds/download/[0-9]*/' | head -1 | grep -o '[0-9]*')
curl -s -c $J -b $J http://127.0.0.1:8083/admin/book/$ID > /tmp/e.html; T=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' /tmp/e.html | head -1)
curl -s -c $J -b $J -o /dev/null -d "csrf_token=$T&book_format_from=epub&book_format_to=azw3" http://127.0.0.1:8083/admin/book/convert/$ID
for i in $(seq 1 60); do find "$L" -name '*.azw3' | grep -q . && break; sleep 2; done
find "$L" -name '*.azw3' | grep -q . && pass "Calibre-Web converted EPUB -> AZW3 with the bundled Calibre" || { fail "no AZW3"; tail -15 $D/data/calibre-web.log; }

echo "== PDF output (Chromium) and covers of PDFs (ImageMagick + Ghostscript)"
mkdir -p /tmp/pdf && chmod 777 /tmp/pdf
sh $A/cw_ctl.sh run $B/calibre/ebook-convert /book/book.epub /tmp/pdf/book.pdf > /tmp/pdf/log.txt 2>&1
[ "$(head -c 5 /tmp/pdf/book.pdf 2>/dev/null)" = "%PDF-" ] && pass "EPUB -> PDF as Calibre-Web's user (with WD's restrictions)" || fail "PDF: $(grep -E 'FATAL|Error|failed' /tmp/pdf/log.txt | tail -3)"
cat > /tmp/pdf/cover.py <<'EOF'
from wand.image import Image
with Image(filename='/tmp/pdf/book.pdf[0]', resolution=72) as img:
    img.format = 'jpeg'
    img.save(filename='/tmp/pdf/cover.jpg')
import magic
print(magic.from_file('/book/book.epub'))
EOF
chmod 644 /tmp/pdf/cover.py
TYPE=$(sh $A/cw_ctl.sh run $B/python/bin/python3 /tmp/pdf/cover.py 2>&1 | tail -1)
[ -s /tmp/pdf/cover.jpg ] && [ "$TYPE" = "EPUB document" ] && pass "a cover from the PDF's first page; libmagic: $TYPE" || fail "covers: $TYPE"

echo "== new password, backups, stopping"
sh $A/cw_ctl.sh new-password > /dev/null; PW2=$(cat $D/admin_password)
[ "$PW2" != "$PW" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW2" http://127.0.0.1:8083/opds)" = 200 ] && pass "a new password works (Calibre-Web restarted for it)" || fail "new password"
sh $A/cw_ctl.sh daily
[ -s $D/backups/*/app.db ] && [ -s $D/backups/*/metadata.db ] && pass "backups: $(ls $D/backups/*/ | tr '\n' ' ')" || fail "backups: $(ls -R $D/backups)"
sh $A/cw_ctl.sh stop > /dev/null; sleep 1
[ "$(ps | grep -c '[c]alibreweb -p')" = 0 ] && pass "stopped" || fail "still running"
