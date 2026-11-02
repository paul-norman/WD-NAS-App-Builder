#!/bin/sh
# phpMyAdmin's HTTPS address from its package (tests/common/nas.sh), with the Nginx app (tests/phpMyAdmin/with): its
# site password (generated, shown and changed on the page), Nginx asking for it first on /phpMyAdmin/, switched off and
# on from the page. Not its MariaDB account (the stand-in has no MariaDB - see tests/mariadb)
. /t/common/nas.sh phpMyAdmin
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
# The NAS always has MariaDB's client: here one that fails, as with MariaDB not running - the page's status runs it
printf '#!/bin/sh\necho "MariaDB is not running" >&2\nexit 1\n' > /usr/bin/mysql && chmod 755 /usr/bin/mysql
DOMAIN=nas.example.test
# Its HTTPS address (Nginx passes /phpMyAdmin/ to the NAS's own web server on port 80: here, nothing answers there)
site() { curl -sk -m 10 --resolve "phpmyadmin.$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "$@" "https://phpmyadmin.$DOMAIN/phpMyAdmin/"; }
# Waits (up to 5 seconds) for Nginx's reload to apply: until its site does (want_401 yes) or doesn't ask for a password
reloaded() { i=0; while [ $i -lt 10 ]; do if [ "$1" = yes ]; then [ "$(site)" = 401 ] && return 0; else [ "$(site)" != 401 ] && return 0; fi; sleep 0.5; i=$((i + 1)); done; return 1; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo "== its HTTPS address's password"
install_app
page_up phpMyAdmin
PW=$(post site_password | j '$d["password"]' | tr -d '"')
[ ${#PW} = 20 ] && [ "$(stat -c '%U %G %a' $D/htpasswd)" = 'root share 640' ] && [ "$(stat -c '%u %a' $D/site_password)" = '0 600' ] \
    && [ "$(stat -c '%a' $D)" = 751 ] && grep -q '"auth_file": "_phpMyAdmin/htpasswd"' $P/phpMyAdmin/nginx.json && [ "$(get status | j '$d["auth"]')" = true ] \
    && pass "generated, shown on the page; its htpasswd file Nginx's workers' group's only, the password root's" || fail "password: '$PW' $(stat -c '%n %U %G %a' $D $D/htpasswd $D/site_password 2>&1)"
grep -q "auth_basic_user_file $D/htpasswd" $P/_nginx/sites/60-app-phpmyadmin.conf && [ "$(site)" = 401 ] && [ "$(site -u admin:wrong)" = 401 ] \
    && [ "$(site -u "admin:$PW")" != 401 ] && [ "$(get status | j '$d["site"]["url"]')" = "\"https://phpmyadmin.$DOMAIN/phpMyAdmin/\"" ] \
    && pass "Nginx asks for it on /phpMyAdmin/: none or a wrong one refused (401), the right one passed on ($(site -u "admin:$PW"): nothing on port 80 here)" \
    || fail "site: $(site) $(site -u "admin:$PW") $(grep -c auth $P/_nginx/sites/60-app-phpmyadmin.conf 2>&1)"
NEW=$(post set_site_password -d password=Suite-pass-1234 | j '$d["password"]' | tr -d '"')
[ "$NEW" = Suite-pass-1234 ] && [ "$(site -u "admin:$PW")" = 401 ] && [ "$(site -u admin:Suite-pass-1234)" != 401 ] \
    && pass 'a new password: the old one refused at once' || fail "new password: $NEW"

echo '== switched off and on'
R=$(post auth -d auth=); reloaded no
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! grep -q auth_file $P/phpMyAdmin/nginx.json && [ "$(site)" != 401 ] && [ "$(get status | j '$d["auth"]')" = false ] \
    && pass "off: no password asked for (only phpMyAdmin's login)" || fail "off: json $(grep -c auth_file $P/phpMyAdmin/nginx.json) site $(site) status $(get status | head -c 400)"
R=$(post auth -d auth=1); reloaded yes
[ "$(site)" = 401 ] && [ "$(site -u admin:Suite-pass-1234)" != 401 ] && pass 'on again: asked for first' || fail "on: $R $(site)"

echo '== removal'
finish_app
[ ! -f $P/_nginx/sites/60-app-phpmyadmin.conf ] && pass 'its site gone from Nginx' || fail "site left: $(ls $P/_nginx/sites)"
