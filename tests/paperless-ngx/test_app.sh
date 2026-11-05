#!/bin/sh
# Paperless-ngx from its package (tests/common/nas.sh), with the Valkey and Nginx apps: its own user in the share group,
# its four processes, its consume folder in the shares, the admin login (and nothing without it), a scanned page dropped
# into the consume folder read by OCR and found by its text, the page (status, the password and a new one, settings:
# the folder - only in the shares - the OCR language, the network), logging in through Nginx (Django's CSRF checks over
# HTTPS), started before Valkey (as at boot), its documents kept across a restart, removal
. /t/common/nas.sh paperless-ngx
DOMAIN=nas.example.test
B=$P/paperless-ngx/binaries
CONSUME=$V/Public/Paperless
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
# Paperless's REST API: api <path> [curl options] (with the token, once there is one)
api() { p=$1; shift; curl -s -m 30 ${TOKEN:+-H "Authorization: Token $TOKEN"} "$@" "http://127.0.0.1:8040$p"; }
# A token for a login: token <password> (empty if refused)
token() { curl -s -m 30 -d username=admin --data-urlencode "password=$1" http://127.0.0.1:8040/api/token/ | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'; }
# Paperless's processes: those of its user (ID 96 - its workers rename themselves)
pythons() { awk '/^Uid:/ && $2 == 96 { split(FILENAME, path, "/"); print path[3] }' /proc/[0-9]*/status 2>/dev/null; }
site() { p=$1; shift; curl -sk -m 30 --resolve "paperless.$DOMAIN:443:127.0.0.1" "$@" "https://paperless.$DOMAIN$p"; }
# Waits for its web server to answer (up to 5 minutes: its first start updates its database)
up() { i=0; while [ $i -lt 150 ]; do [ "$(code -m 5 http://127.0.0.1:8040/accounts/login/)" = 200 ] && return 0; sleep 2; i=$((i + 1)); done; return 1; }
# A page image with text on it (as a scanner makes): page <file> <text>
page() {
    $B/python/bin/python3 -c '
import sys
from PIL import Image, ImageDraw, ImageFont
image = Image.new("L", (1240, 1754), 255)
font = ImageFont.truetype(sys.argv[3], 64)
ImageDraw.Draw(image).text((120, 200), sys.argv[2], fill=0, font=font)
image.save(sys.argv[1], dpi=(150, 150))' "$1" "$2" $B/fonts/LiberationSerif-Regular.ttf
}

# As on WD's NAS: no /dev/shm (Celery's worker pool needs one: the app mounts it)
umount /dev/shm 2>/dev/null; rm -rf /dev/shm
echo '== with Valkey and Nginx'
install_app valkey
wait_port 6379 30 && pass 'Valkey answering' || { fail "Valkey: $(tail -n 5 /tmp/start.log)"; exit 1; }
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== installed and started'
install_app
up && pass "answering on 8040 ($(cat $D/state))" || { fail "not answering: $(tail -n 30 $D/paperless.log)"; exit 1; }
N=0
for service in web consumer worker scheduler; do
    pid=$(cat /var/run/paperless-ngx/$service.pid 2>/dev/null)
    [ -n "$pid" ] && [ -d /proc/$pid ] && N=$((N + 1))
done
UIDS=$(for pid in $(pythons); do awk '/^Uid:/ { print $2 }' /proc/$pid/status; done | sort -u | tr '\n' ' ')
GIDS=$(for pid in $(pythons); do awk '/^Gid:/ { print $2 }' /proc/$pid/status; done | sort -u | tr '\n' ' ')
[ $N = 4 ] && [ "$UIDS" = '96 ' ] && [ "$GIDS" = '1000 ' ] && pass 'its web server, consumer, task worker and scheduler, all as its own user (96) in the share group' \
    || fail "processes: $N, uids $UIDS gids $GIDS"
[ "$(stat -c '%U %a' $D/data)" = 'paperless 700' ] && [ "$(stat -c '%U %a' $D/media)" = 'paperless 700' ] && [ "$(stat -c '%u %a' $D/admin_password)" = '0 600' ] \
    && [ "$(stat -c '%u %a' $D/secret_key)" = '0 600' ] && [ -f $D/data/db.sqlite3 ] && pass 'its database and documents its own, its secrets root'"'"'s' || fail "data: $(ls -la $D)"
awk '$2 == "/dev/shm" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/self/mounts && [ "$(stat -c '%a' /dev/shm)" = 1777 ] \
    && pass 'a shared memory file system mounted on /dev/shm (the NAS has none; Celery needs one)' || fail "/dev/shm: $(ls -ld /dev/shm 2>&1)"
[ -d $CONSUME ] && [ "$(stat -c '%U %G %a' $CONSUME)" = 'paperless share 2775' ] && pass "its consume folder made in the shares: $CONSUME (the share group's)" || fail "consume: $(ls -ld $CONSUME)"

echo '== its login'
[ -z "$(token wrong)" ] && pass 'a wrong password refused' || fail 'wrong password accepted'
[ "$(code -m 10 http://127.0.0.1:8040/api/documents/)" = 401 ] && pass 'nothing without a login (401)' || fail "no login: $(code -m 10 http://127.0.0.1:8040/api/documents/)"
TOKEN=$(token "$(cat $D/admin_password)")
[ -n "$TOKEN" ] && api /api/ui_settings/ | grep -q '"username":"admin"' && pass 'the admin user, with the generated password' || fail "admin: $TOKEN"
# Its System Status (no documents yet): the search index made at the first start, as Paperless's own image does
R=$(api /api/status/); [ -n "$(ls -A $D/data/index 2>/dev/null)" ] && echo "$R" | grep -q '"index_status":"OK"' \
    && pass 'its search index made at the first start (System Status: OK, no documents yet)' || fail "index: $(ls -la $D/data/index 2>&1) $(echo "$R" | grep -o '"index[^,]*,"index[^,]*' )"

echo '== a scanned page'
page /tmp/scan.png 'Invoice 4711 from the NAS'
cp /tmp/scan.png $CONSUME/scan.png && chmod 664 $CONSUME/scan.png
i=0; while [ $i -lt 90 ] && ! api '/api/documents/?content__icontains=4711' | grep -q '"count":1'; do sleep 2; i=$((i + 1)); done
R=$(api '/api/documents/?content__icontains=4711')
echo "$R" | grep -q '"count":1' && echo "$R" | grep -q 'Invoice 4711 from the NAS' && [ ! -e $CONSUME/scan.png ] \
    && pass "dropped into the consume folder: imported, read by OCR, found by its text (in $((i * 2))s), removed from the folder" \
    || { fail "consume: $(echo "$R" | head -c 300)"; echo '-- its log:'; grep -h -B3 -A15 'Error during processing' $D/data/log/*.log | tail -n 40; echo '-- OCRmyPDF by hand:'; env -i PATH=$B/bin:$B/python/bin:/usr/bin:/bin \
        TESSDATA_PREFIX=$B/tessdata MAGIC=$B/magic.mgc HOME=/tmp GS_OPTIONS=-sICCProfilesDir=$B/icc/ghostscript/ \
        GS_LIB=$B/ghostscript/Resource/Init:$B/ghostscript/lib:$B/ghostscript/Resource/Font \
        $B/python/bin/python3 -m ocrmypdf -v 1 --image-dpi 150 --clean /tmp/scan.png /tmp/by-hand.pdf 2>&1 | grep -iv 'debug' | tail -n 40; }
ID=$(echo "$R" | sed -n 's/.*"results":\[{"id":\([0-9]*\).*/\1/p')
[ "$(api /api/documents/$ID/download/ -o /tmp/archive.pdf -w '%{http_code}')" = 200 ] && head -c 5 /tmp/archive.pdf | grep -q '%PDF' \
    && [ -n "$(find $D/media/documents/archive -name '*.pdf')" ] && pass 'its searchable PDF made and kept in its data folder' || fail "archive: $(ls -R $D/media | head)"

echo '== its page'
page_up paperless-ngx
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"] && !in_array(false, $d["services"], true)')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"3.4.2"' ] \
    && echo "$ST" | j '$d["address"]' | grep -q ':8040/"$' && pass "status: running (its four processes), 3.4.2, $(echo "$ST" | j '$d["address"]')" \
    || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password -d show=1 | j '$d["password"]')" = "\"$(cat $D/admin_password)\"" ] && pass 'the password shown' || fail 'password'
OLD=$(cat $D/admin_password); NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"')
[ ${#NEW} = 20 ] && [ "$NEW" != "$OLD" ] && [ -z "$(token "$OLD")" ] && [ -n "$(token "$NEW")" ] \
    && pass 'a new password, at once (nothing restarted): it works, the old one no longer does' || fail "new password: ${#NEW}"
R1=$(post settings -d consume_dir=$P/_paperless-ngx -d ocr_language=eng); R2=$(post settings -d consume_dir=$CONSUME --data-urlencode ocr_language=fra)
[ "$(echo "$R1" | j '$d["ok"]')" = false ] && [ "$(echo "$R2" | j '$d["ok"]')" = false ] && pass "refused: a folder in Nas_Prog, an OCR language it doesn't have" || fail "refusals: $R1 $R2"
mkdir -p $V/Public/Scans
R1=$(post settings -d consume_dir=$V/Public/Scans --data-urlencode ocr_language=eng+deu -d listen=all); up
# In use: a page dropped into the new folder is imported, read with both languages
page /tmp/scan2.png 'Rechnung 4712 vom NAS'
cp /tmp/scan2.png $V/Public/Scans/scan2.png && chmod 664 $V/Public/Scans/scan2.png
TOKEN=$(token "$NEW")
i=0; while [ $i -lt 90 ] && ! api '/api/documents/?content__icontains=4712' | grep -q '"count":1'; do sleep 2; i=$((i + 1)); done
[ "$(echo "$R1" | j '$d["ok"]')" = true ] && api '/api/documents/?content__icontains=4712' | grep -q '"count":1' \
    && grep 'Calling OCRmyPDF with args' $D/data/log/paperless.log | tail -n 1 | grep -q "'language': 'eng+deu'" \
    && pass 'settings saved and in use (restarted from the page): a page in the new folder imported, read in English and German' \
    || { fail "settings: $R1 $(grep -o "'language': '[a-z+]*'" $D/data/log/paperless.log | sort -u | tr '\n' ' ') $(cat $D/state)"; tail -n 30 $D/paperless.log; }
TOKEN=$(token "$NEW")
api '/api/documents/?content__icontains=4711' | grep -q '"count":1' && pass 'its documents kept across the restart' || fail 'documents gone'

echo '== through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8040' $P/_nginx/sites/60-app-paperless.conf 2>/dev/null && grep -q 'client_max_body_size' $P/_nginx/sites/60-app-paperless.conf \
    && pass 'its site, with uploads' || fail "site: $(ls $P/_nginx/sites)"
rm -f /tmp/jar; site /accounts/login/ -c /tmp/jar > /tmp/login.html
CSRF=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
C=$(site /accounts/login/ -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' -H "Referer: https://paperless.$DOMAIN/accounts/login/" \
    -H "Origin: https://paperless.$DOMAIN" --data-urlencode "csrfmiddlewaretoken=$CSRF" -d login=admin --data-urlencode "password=$NEW")
echo "$C" | grep -q '^302 ' && [ "$(site /api/ui_settings/ -b /tmp/jar -o /dev/null -w '%{http_code}')" = 200 ] \
    && pass "logged in through https://paperless.$DOMAIN/ (its login form, Django's CSRF checks over HTTPS)" || fail "login through Nginx: $C $(grep -o 'errorlist[^<]*<[^<]*' /tmp/login.html | head -n 2)"
[ "$(get status | j '$d["site"]["url"]')" = "\"https://paperless.$DOMAIN/\"" ] && pass 'the page shows its site' || fail "site: $(get status | j '$d["site"]')"

echo '== started before Valkey (as at boot)'
sh $P/paperless-ngx/stop.sh $P/paperless-ngx > /dev/null 2>&1; sh $P/valkey/stop.sh $P/valkey > /dev/null 2>&1
sh $P/paperless-ngx/start.sh $P/paperless-ngx > /dev/null 2>&1; sleep 8
[ "$(cat $D/state)" = 'waiting for Valkey' ] && [ "$(get status | j '$d["launching"]')" = true ] && pass 'it waits for Valkey (the page says so)' || fail "waiting: $(cat $D/state)"
sh $P/valkey/start.sh $P/valkey > /dev/null 2>&1
up && TOKEN=$(token "$NEW") && api '/api/documents/?content__icontains=4711' | grep -q '"count":1' && pass 'Valkey started: Paperless up by itself, its documents there' || { echo '-- after Valkey, its log:'; tail -n 25 $D/paperless.log; ls -la /var/run/paperless-ngx; fail "after Valkey: $(cat $D/state) - Valkey: $(cat /var/run/valkey.pid 2>&1) $(VALKEYCLI_AUTH=$(awk '$1 == "requirepass" { print $2 }' $P/_valkey/valkey.conf) $P/valkey/binaries/valkey-cli -p 6379 ping 2>&1) listening: $(cat /proc/net/tcp /proc/net/tcp6 | awk '$4 == "0A" { print $2 }' | tr '\n' ' ') valkey sockets: $(ls -l /proc/$(cat /var/run/valkey.pid)/fd | grep -c socket) ipv6 ping: $($P/valkey/binaries/valkey-cli -h ::1 -p 6379 ping 2>&1) servers: $(pgrep -af valkey-server | tr '\n' ';') alive: $(kill -0 $(cat /var/run/valkey.pid) 2>&1 && echo yes) state: $(grep State /proc/$(cat /var/run/valkey.pid)/status) wchan: $(cat /proc/$(cat /var/run/valkey.pid)/wchan) threads: $(ls /proc/$(cat /var/run/valkey.pid)/task | wc -l) fds: $(ls -l /proc/$(cat /var/run/valkey.pid)/fd | tail -n +2 | awk '{ print $NF }' | tr '\n' ' ') $(tail -n 12 $P/valkey/valkey.log 2>&1 | tr '\n' ' ') $(grep -i valkey /tmp/debug_apkg | tail -n 5 | tr '\n' ' ')"; }

echo '-- Valkey'"'"'s log:'; tail -n 30 $P/valkey/valkey.log
echo '== removal'
finish_app
[ -z "$(pythons)" ] && [ ! -f $P/_nginx/sites/60-app-paperless.conf ] && [ -f $D/data/db.sqlite3 ] \
    && pass 'all its processes stopped, its site gone, its documents kept' || fail "removal: $(pythons | tr '\n' ' ')"
finish_app nginx
finish_app valkey
