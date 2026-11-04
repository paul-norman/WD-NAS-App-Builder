#!/bin/sh
# Bugsink from its package (tests/common/nas.sh), with the Nginx app (tests/bugsink/with): its first start (databases,
# admin user) as its own user, only on the NAS itself, its address (the Nginx app's site) in its settings, logging in
# through its site, an error reported with Sentry's SDK becoming an issue (its worker), a new password from the page,
# the network setting, a restart keeping its data, removal
. /t/common/nas.sh bugsink
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
CONF=$D/conf/bugsink_conf.py
site() { p=$1; shift; curl -sk -m 15 --resolve "bugsink.$DOMAIN:443:127.0.0.1" "$@" "https://bugsink.$DOMAIN$p"; }
# Python as Bugsink runs it: its own user, its settings - for its management commands and Sentry's SDK
bpy() { (cd $D/conf && PYTHONPATH=$D/conf DJANGO_SETTINGS_MODULE=bugsink_conf HOME=$D/data $P/bugsink/binaries/bugsink_runas 92 92 $P/bugsink/binaries/python/bin/python3 "$@"); }
issues() { bpy -m bugsink.scripts.manage shell -c 'from issues.models import Issue; print(Issue.objects.count())' 2>/dev/null | tail -n 1; }
# Logs in on its own form through its site (Django's CSRF token from the login page): prints where it was sent
login() {
    rm -f /tmp/jar; site /accounts/login/ -c /tmp/jar -o /tmp/login.html
    TOKEN=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' /tmp/login.html | head -n 1)
    site /accounts/login/ -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' -H "Referer: https://bugsink.$DOMAIN/accounts/login/" \
        --data-urlencode "csrfmiddlewaretoken=$TOKEN" --data-urlencode "username=$1" --data-urlencode "password=$2"
}

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 8000 150 && pass 'answering on 8000' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 10 $D/bugsink.log)"; exit 1; }
PID=$(cat /var/run/bugsink.pid); WPID=$(cat /var/run/bugsink-snappea.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 92 ] && [ "$(awk '/^Uid:/ { print $2 }' /proc/$WPID/status)" = 92 ] \
    && pass 'its web server and its worker run as its own user (92)' || fail "users: $(awk '/^Uid:/' /proc/$PID/status /proc/$WPID/status)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1F40") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
[ "$(stat -c '%U %G %a' $CONF)" = 'root bugsink 640' ] && [ "$(stat -c '%U %a' $D/data)" = 'bugsink 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] \
    && [ "$(stat -c '%u %a' $D/secret_key)" = '0 600' ] && [ -s $D/data/db.sqlite3 ] && [ -s $D/data/snappea.sqlite3 ] \
    && pass "its databases made; its settings root's (its group reads them), its data its own, its password and secret key root's" || fail "files: $(stat -c '%n %U %G %a' $CONF $D/data $D/password $D/secret_key)"
grep -q "\"BASE_URL\": \"https://bugsink.$DOMAIN\"" $CONF && grep -q '^SESSION_COOKIE_SECURE = True' $CONF && grep -q "\"bugsink.$DOMAIN\"" $CONF \
    && pass "its address is the Nginx app's site (https://bugsink.$DOMAIN), its cookies secure" || fail "settings: $(grep -E 'BASE_URL|COOKIE_SECURE|ALLOWED' $CONF)"

echo '== logging in, through its site'
grep -q 'proxy_pass *http://127.0.0.1:8000' $P/_nginx/sites/60-app-bugsink.conf 2>/dev/null && R=$(login admin "$(cat $D/password)") && echo "$R" | grep -q '^302 .*/$' \
    && ! site / -b /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' | grep -q 'accounts/login' && pass "admin logs in on its form through its site ($R)" || fail "login: $R $(grep -o 'errorlist[^<]*<[^<]*' /tmp/login.html | head -n 2)"
R=$(login admin wrong-password-1)
echo "$R" | grep -q '^200' && pass 'a wrong password refused (the form again)' || fail "wrong password: $R"

echo '== an error reported to it'
DSN=$(bpy -m bugsink.scripts.manage shell -c "
from teams.models import Team
from projects.models import Project
team = Team.objects.create(name='Home')
print(Project.objects.create(name='Suite', team=team).dsn)" 2>/dev/null | tail -n 1)
echo "$DSN" | grep -q "^https://[0-9a-f]*@bugsink.$DOMAIN/[0-9]*$" && pass "a project's DSN uses its address: $(echo "$DSN" | sed 's#//[0-9a-f]*@#//<key>@#')" || fail "DSN: $DSN"
# Sent to it directly (this container doesn't trust the Nginx app's certificate)
LOCAL_DSN=$(echo "$DSN" | sed "s#^https://\([0-9a-f]*\)@bugsink.$DOMAIN/#http://\1@127.0.0.1:8000/#")
bpy -c 'import sys, sentry_sdk
sentry_sdk.init(dsn=sys.argv[1])
try:
    1 / 0
except ZeroDivisionError:
    sentry_sdk.capture_exception()
sentry_sdk.flush()' "$LOCAL_DSN" > /tmp/sdk.log 2>&1
i=0; until [ "$(issues)" = 1 ] || [ $i -ge 60 ]; do sleep 3; i=$((i + 3)); done
[ "$(issues)" = 1 ] && pass "an error sent with Sentry's SDK became an issue (its worker, after ${i}s)" || fail "issue: $(issues) $(tail -n 3 /tmp/sdk.log) $(tail -n 5 $D/bugsink.log)"

echo '== its page'
page_up bugsink
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["worker"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"2.6.2"' ] \
    && [ "$(echo "$ST" | j '$d["base_url"]')" = "\"https://bugsink.$DOMAIN\"" ] && pass "the page: Bugsink 2.6.2 answering, its worker running, its address" || fail "status: $(echo "$ST" | head -c 400)"
OLD=$(cat $D/password)
[ "$(post password | j '$d["password"]')" = "\"$OLD\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && login admin Brand.New-Password_1 | grep -q '^302' && login admin "$OLD" | grep -q '^200' \
    && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && awk 'NR > 1 && $4 == "0A" && index($2, ":1F40") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && grep -q '^SESSION_COOKIE_SECURE = False' $CONF && grep -q "\"BASE_URL\": \"https://bugsink.$DOMAIN\"" $CONF \
    && pass 'on the network too (0.0.0.0:8000): its cookies then not secure-only (plain HTTP works), its address still the site' || fail "listen all: $R"
post listen -d listen=local > /dev/null
grep -q '^SESSION_COOKIE_SECURE = True' $CONF && pass 'and back to the NAS only' || fail 'listen local'

echo '== restart'
sh $P/bugsink/stop.sh $P/bugsink > /dev/null 2>&1
listening 8000 && fail 'still answering once stopped' || true
sh $P/bugsink/start.sh $P/bugsink > /tmp/start.log 2>&1
wait_port 8000 120 && [ "$(issues)" = 1 ] && login admin Brand.New-Password_1 | grep -q '^302' && pass 'restarted: its issue kept, the same login' || fail "restart: issues $(issues), $(tail -n 3 /tmp/debug_apkg)"

echo '== removal'
finish_app
! grep -q bugsink-daily /var/spool/cron/crontabs/root && [ ! -f /var/run/bugsink-snappea.pid ] && pass 'its cron line gone, its worker stopped' || fail 'left behind'
