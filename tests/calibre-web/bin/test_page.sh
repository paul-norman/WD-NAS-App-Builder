#!/bin/sh
# The management page's API (on this image's PHP), as the dashboard calls it - with an admin's WD session and the page's
# CSRF token - against a running Calibre-Web
A=/mnt/HD/HD_a2/Nas_Prog/calibre-web; D=/mnt/HD/HD_a2/Nas_Prog/_calibre-web; P=/mnt/HD/HD_a2/Public
. /t/bin/setup.sh
mkdir -p /var/www/apps && ln -s $A/manage /var/www/apps/calibre-web
echo "PHP $(php -r 'echo PHP_VERSION;')"
sh $A/cw_ctl.sh start > /dev/null 2>&1
echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &
sleep 1
B=http://127.0.0.1:8080/apps/calibre-web; CK='Cookie: PHPSESSID=adminsession123'
T=$(curl -s -H "$CK" $B/index.php | sed -n 's/.*let csrf *= "\([^"]*\)".*/\1/p')
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }

ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && echo "$ST" | j '$d["versions"]["calibre"]' | grep -q '"9\.' \
    && pass "status: running, versions $(echo "$ST" | j '$d["versions"]'), library $(echo "$ST" | j '$d["library"]')" || fail "status: $(echo "$ST" | cut -c1-300)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Requested-With: XMLHttpRequest' $B/api.php?action=status)" = 403 ] && pass 'without a NAS login: refused' || fail 'no session allowed'
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d show=1 "$B/api.php?action=password")" = 403 ] && pass 'a wrong CSRF token: refused' || fail 'csrf'
PW=$(post password -d show=1 | j '$d["password"]' | tr -d '"'); [ "$PW" = "$(cat $D/admin_password)" ] && pass 'password shown' || fail 'password'
R=$(post settings -d listen=all -d ingest=1 -d "ingest_folder=$P/Books/Add to library" -d ingest_convert=epub)
grep -q '^INGEST=1' $D/settings && grep -q '^INGEST_CONVERT=epub' $D/settings && [ -d "$P/Books/Add to library" ] && pass 'ingest folder turned on (and created)' || fail "settings: $R"
post settings -d listen=all -d ingest=1 -d "ingest_folder=$P/Books/Calibre Library/x" -d ingest_convert=none | grep -q 'separate' && pass 'an ingest folder inside the library refused' || fail 'inside the library'
post settings -d listen=all -d ingest=0 -d 'ingest_folder=/mnt/HD/HD_a2/Nas_Prog/x' | grep -q 'Nas_Prog' && pass 'a folder in Nas_Prog refused' || fail 'Nas_Prog'
mkdir -p "$P/Other"; echo x > "$P/Other/file.txt"
post library -d "library=$P/Other" | grep -q "isn't a Calibre library" && pass "a folder that isn't a library (and isn't empty) refused" || fail 'library check'
R=$(post library -d "library=$P/Books/Second Library")
[ -f "$P/Books/Second Library/metadata.db" ] && [ "$(get status | j '$d["library"]')" = "\"$P/Books/Second Library\"" ] && pass 'switched to a new library (created, Calibre-Web restarted)' || fail "library: $R"
R=$(post new_password -d confirm=1); NEW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$NEW" http://127.0.0.1:8083/opds)" = 200 ] && pass 'a new password from the page' || fail "new password: $R"
grep -i -E 'warning|fatal|deprecated|notice' /tmp/php.log | head -5
sh $A/cw_ctl.sh stop > /dev/null
