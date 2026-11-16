#!/bin/sh
# linkding from its package (tests/common/nas.sh), with the Nginx app (tests/linkding/with): its first start (database,
# secret key, admin user) as its own user, only on the NAS itself, its data where the app keeps it, logging in through
# its site (Django's CSRF check with its Nginx address), a bookmark through its REST API, the page (status, the
# password and a new one), a restart keeping its data, backups (linkding's own, with the bookmark), the network
# setting, removal keeping its data
. /t/common/nas.sh linkding
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
H=http://127.0.0.1:9099
site() { p=$1; shift; curl -sk -m 15 --resolve "linkding.$DOMAIN:443:127.0.0.1" "$@" "https://linkding.$DOMAIN$p"; }
# One of linkding's management commands, as the app runs them: lmanage <command> [arguments]
lmanage() { (cd $P/linkding/binaries/linkding && HOME=$D/data DJANGO_SETTINGS_MODULE=bookmarks.settings.prod LD_LIBRARY_PATH=$P/linkding/binaries/python/lib \
    $P/linkding/binaries/linkding_runas 56 56 $P/linkding/binaries/python/bin/python3 manage.py "$@"); }
# Logs in on its own form through its site (Django's CSRF token from the login page): prints the status and where it
# was sent
login() {
    rm -f /tmp/jar; site /login/ -c /tmp/jar -o /tmp/login.html
    TOKEN=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    site /login/ -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' -H "Origin: https://linkding.$DOMAIN" \
        -H "Referer: https://linkding.$DOMAIN/login/" --data-urlencode "csrfmiddlewaretoken=$TOKEN" --data-urlencode "username=$1" --data-urlencode "password=$2"
}
# Its REST API, with the admin's token: api <path> [curl options]
api() { p=$1; shift; curl -s -m 15 -H "Authorization: Token $APITOKEN" "$@" "$H/api/$p"; }
# Whether it listens beyond the NAS itself (port 9099 = 238B)
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":238B") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
curl -s $H/login/ | grep -qi linkding && pass 'answering on 9099' \
    || { fail "not answering: $(tail -n 10 /tmp/start.log; grep linkding /tmp/debug_apkg | tail -n 10; tail -n 10 $D/linkding.log)"; exit 1; }
PID=$(cat /var/run/linkding.pid); WPID=$(cat /var/run/linkding-tasks.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 56 ] && [ "$(awk '/^Uid:/ { print $2 }' /proc/$WPID/status)" = 56 ] \
    && pass 'its web server and its worker run as its own user (56)' || fail "users: $(awk '/^Uid:/' /proc/$PID/status /proc/$WPID/status)"
! listens_beyond && grep -q '^LISTEN=local$' $D/settings && pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there' || fail 'listens beyond the NAS'
[ "$(stat -c '%U %a' $D/data)" = 'linkding 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ -s $D/data/db.sqlite3 ] && [ -s $D/data/secretkey.txt ] \
    && [ "$(readlink $P/linkding/binaries/linkding/data)" = "$D/data" ] \
    && pass 'its database and secret key in Nas_Prog/_linkding/data (its own; linked from linkding'"'"'s folder), its password root'"'"'s' \
    || fail "files: $(ls -la $D $D/data; readlink $P/linkding/binaries/linkding/data)"
grep -q 'linkding-daily' /var/spool/cron/crontabs/root && grep -q 'linkding-update-check' /var/spool/cron/crontabs/root \
    && pass 'its daily backup and weekly update check in cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"

echo '== its admin, through its site'
PW=$(cat $D/password)
R=$(login admin "$PW")
case "$R" in
    302*/bookmarks*) pass "the admin logs in through its site https://linkding.$DOMAIN/ (its CSRF check passed)" ;;
    *) fail "login: $R $(tail -n 5 $D/linkding.log)" ;;
esac
[ "$(login admin wrong-password | cut -c1-3)" = 401 ] && pass 'a wrong password refused' || fail 'a wrong password accepted'
[ "$(curl -s -o /dev/null -w '%{http_code}' $H/bookmarks)" = 302 ] && pass 'its bookmarks not shown without logging in' || fail 'anonymous bookmarks'

echo '== a bookmark'
APITOKEN=$(lmanage shell -c "from django.contrib.auth.models import User; from bookmarks.models import ApiToken; print(ApiToken.objects.create(user=User.objects.get(username='admin'), name='test').key)" 2>/dev/null | tail -n 1)
R=$(api bookmarks/ -H 'Content-Type: application/json' -d '{"url":"https://example.com/nas-page","title":"A page about the NAS","tag_names":["nas"]}')
echo "$R" | grep -q '"id"' && api 'bookmarks/?q=%23nas' | grep -q 'A page about the NAS' \
    && pass 'a bookmark added and found by its tag (its REST API)' || fail "bookmark: $R"

echo '== its page'
page_up linkding
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["worker"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"1.47.0"' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://linkding.$DOMAIN/\"" ] && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] \
    && pass 'status: running (its worker too), linkding 1.47.0, its site, the admin'"'"'s password' || fail "status: $(echo "$ST" | head -c 400)"
R=$(post set_password -d password=); NEW=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && login admin "$NEW" | grep -q '^302' && [ "$(login admin "$PW" | cut -c1-3)" = 401 ] && [ "$(cat $D/password)" = "$NEW" ] \
    && pass 'a new password from the page (the old one refused)' || fail "new password: $R"
[ "$(post set_password -d password=short | j '$d["ok"]')" = false ] && pass 'a short password refused' || fail 'a short password accepted'
sh $P/linkding/linkding_ctl.sh restart > /tmp/restart.log 2>&1
login admin "$NEW" | grep -q '^302' && api 'bookmarks/?q=%23nas' | grep -q 'A page about the NAS' \
    && [ "$(lmanage shell -c 'from django.contrib.auth.models import User; print(User.objects.count())' 2>/dev/null | tail -n 1)" = 1 ] \
    && pass 'restarted: its password and bookmark kept, no second admin' || fail "restart: $(tail -n 5 /tmp/restart.log)"

echo '== backups'
R=$(post backup -d confirm=1)
F=$(ls $D/backups/linkding-*.zip 2>/dev/null | head -n 1)
rm -rf /tmp/restore; mkdir -p /tmp/restore && python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$F" /tmp/restore 2>/dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%U %a' "$F")" = 'root 600' ] \
    && [ "$(python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT title FROM bookmarks_bookmark").fetchone()[0])' /tmp/restore/db.sqlite3 2>/dev/null)" = 'A page about the NAS' ] \
    && [ -z "$(ls $D/tmp)" ] && pass 'a backup from the page (linkding'"'"'s own), root'"'"'s only, with the bookmark in it' || fail "backup: $R $(ls -la $D/backups $D/tmp)"
post settings -d listen=local -d backup_keep=2 > /dev/null
for i in 1 2 3; do sleep 1; sh $P/linkding/linkding_ctl.sh backup > /dev/null 2>&1; done
[ "$(ls $D/backups/linkding-*.zip | wc -l)" = 2 ] && pass 'only the newest 2 kept' || fail "kept: $(ls $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'on the network too (0.0.0.0:9099)' || fail "listen all: $R"
post settings -d listen=local -d backup_keep=14 > /dev/null
! listens_beyond && login admin "$NEW" | grep -q '^302' && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'linkding-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-linkding.conf ] && [ -f $D/data/db.sqlite3 ] \
    && pass 'its cron lines and site gone, its data kept' || fail 'left behind'
finish_app nginx
