#!/bin/sh
# Tautulli from its package (tests/common/nas.sh), with the Nginx app (tests/tautulli/with): its first start as its own
# user, only on the NAS itself, a login from the start (its password hashed by Tautulli), no update checks, its own login
# form, its site through Nginx, a new password from the page, the network setting, a restart keeping its data, removal
. /t/common/nas.sh tautulli
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
U=http://127.0.0.1:8181
C=$D/data/config.ini
# A setting from Tautulli's config.ini
cfg() { sed -n "s/^$1 = //p" $C | head -n 1; }
# Signs in on Tautulli's own form, as its page does (the CSRF token from the login page, with its session): prints the
# status code (200 when the login is right)
signin() {
    rm -f /tmp/jar; T=$(curl -s -c /tmp/jar -b /tmp/jar $U/auth/login | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p')
    curl -s -c /tmp/jar -b /tmp/jar -o /tmp/signin.json -w '%{http_code}' -H "X-CSRF-Token: $T" -H 'X-Requested-With: XMLHttpRequest' \
        --data-urlencode "username=$1" --data-urlencode "password=$2" -d remember_me=0 $U/auth/signin
}
site() { p=$1; shift; curl -sk -m 10 --resolve "tautulli.$DOMAIN:443:127.0.0.1" "$@" "https://tautulli.$DOMAIN$p"; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 8181 150 && pass 'answering on 8181' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 5 $D/tautulli.out)"; exit 1; }
PID=$(cat /var/run/tautulli.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 93 ] && [ "$(stat -c '%U %a' $D/data)" = 'tautulli 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass "runs as its own user (93), its data its own; the password the app set root's" || fail "users: $(stat -c '%n %U %a' $D $D/data $D/password)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1FF5") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
case "$(cfg http_password)" in PBKDF2\$*) H=1 ;; *) H=0 ;; esac
[ $H = 1 ] && [ "$(cfg http_hashed_password)" = 1 ] && [ "$(cfg http_username)" = admin ] && ! grep -q "$(cat $D/password)" $C \
    && pass "its login from the start: admin, the password hashed by Tautulli in its settings ($(cfg http_password | cut -c1-22)…)" || fail "login settings: $(grep http_ $C)"
[ "$(cfg check_github)" = 0 ] && [ "$(cfg check_github_on_startup)" = 0 ] && [ "$(cfg launch_browser)" = 0 ] && [ "$(cfg http_host)" = 127.0.0.1 ] \
    && pass 'no update checks (the Store updates it), no browser to open' || fail "settings: $(grep -E 'check_github|launch_browser|http_host' $C)"

echo '== its login'
R=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $U/)
echo "$R" | grep -q '^303 .*/auth/' && [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/v2?cmd=status")" = 401 ] \
    && pass "nothing shown without logging in: $R; its API refused (401)" || fail "open: $R"
[ "$(signin admin "$(cat $D/password)")" = 200 ] && grep -q '"status": *"success"' /tmp/signin.json && [ "$(curl -s -b /tmp/jar -o /dev/null -w '%{http_code}' $U/welcome)" = 200 ] \
    && pass "the page's password logs in on Tautulli's own form, its setup then open" || fail "sign in: $(cat /tmp/signin.json)"
[ "$(signin admin wrong-password-1)" != 200 ] && pass "a wrong password refused: $(cut -c1-60 /tmp/signin.json)" || fail 'wrong password accepted'

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8181' $P/_nginx/sites/60-app-tautulli.conf 2>/dev/null && site /auth/login | grep -q '<title>Tautulli' \
    && pass "its site https://tautulli.$DOMAIN/ reaches Tautulli's login" || fail "site: $(ls $P/_nginx/sites; site /auth/login | head -c 200)"

echo '== its page'
page_up tautulli
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"2.19.0"' ] && [ "$(echo "$ST" | j '$d["set_up"]')" = false ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://tautulli.$DOMAIN/\"" ] && [ "$(echo "$ST" | j '$d["plex"]')" = false ] \
    && pass "the page: Tautulli 2.19.0 answering, not set up yet, its address https://tautulli.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
OLD=$(cat $D/password)
[ "$(post password | j '$d["password"]')" = "\"$OLD\"" ] && pass 'the page shows the password' || fail 'password not shown'
[ "$(post set_password -d password=short | j '$d["ok"]')" = false ] && pass 'a short password refused' || fail 'short password accepted'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && wait_port 8181 60 && [ "$(signin admin Brand.New-Password_1)" = 200 ] && [ "$(signin admin "$OLD")" != 200 ] \
    && pass 'a new password from the page: Tautulli restarted with it, the old one refused' || fail "new password: $R $(cat /tmp/signin.json)"

echo '== on the network'
R=$(post listen -d listen=all)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(cfg http_host)" = 0.0.0.0 ] && awk 'NR > 1 && $4 == "0A" && index($2, ":1FF5") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && pass 'on the network too (0.0.0.0:8181)' || fail "listen all: $R $(cfg http_host)"
post listen -d listen=local > /dev/null
[ "$(cfg http_host)" = 127.0.0.1 ] && pass 'and back to the NAS only' || fail "listen local: $(cfg http_host)"

echo '== restart'
DB=$(stat -c %s $D/data/tautulli.db)
sh $P/tautulli/stop.sh $P/tautulli > /dev/null 2>&1
listening 8181 && fail 'still answering once stopped' || true
sh $P/tautulli/start.sh $P/tautulli > /tmp/start.log 2>&1
wait_port 8181 120 && [ "$(signin admin Brand.New-Password_1)" = 200 ] && [ -s $D/data/tautulli.db ] \
    && pass "restarted: its database kept ($DB bytes), the same login" || fail "restart: $(tail -n 5 /tmp/start.log)"
grep -i -E ' - (ERROR|CRITICAL) ' $D/data/logs/tautulli.log | grep -v -i 'plex\|pms\|server' | head -3

echo '== removal'
finish_app
! grep -q tautulli-daily /var/spool/cron/crontabs/root && pass 'its cron line gone' || fail 'cron line left'
