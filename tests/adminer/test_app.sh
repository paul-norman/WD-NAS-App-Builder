#!/bin/sh
# Adminer from its package (tests/common/nas.sh), with the PostgreSQL and Valkey apps and the PHP app's PHP
# (tests/adminer/with - only its programs: its start swaps WD's own PHP): first on the NAS's own PHP (a stand-in: the
# image's - PHP 7.4 in its 7.4 run - with its own php.ini), then moved to the PHP app's; as its own user on PHP's own
# server (4 workers), on the network or only on the NAS itself, Valkey and PostgreSQL logins on Adminer's own form (and
# wrong ones refused), new passwords for its site, stopping with its workers, removal
. /t/common/nas.sh adminer
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
U=http://127.0.0.1:8084
JAR=/tmp/adminer.cookies
# Adminer's login form has a CSRF token of its own, for its session: a login without it is ignored
form() { rm -f $JAR; TOKEN=$(curl -s -m 5 -c $JAR -b $JAR $U/ | sed -n "s/.*name='token' value='\([^']*\)'.*/\1/p" | head -n 1); }
# A login on Adminer's form: login <password> [driver user database] (PostgreSQL's postgres by default)
login() { curl -s -m 10 -b $JAR -c $JAR -o /tmp/login.html -w '%{redirect_url}' $U/ --data-urlencode "token=$TOKEN" --data-urlencode "auth[driver]=${2:-pgsql}" \
    --data-urlencode 'auth[server]=127.0.0.1' --data-urlencode "auth[username]=${3:-postgres}" --data-urlencode "auth[password]=$1" --data-urlencode "auth[db]=${4:-postgres}"; }

echo "== without the PHP app: on the NAS's own PHP"
# The NAS's PHP and its php.ini, where WD has them: here the image's PHP
mkdir -p /usr/local/modules/usr/bin /etc/php && ln -sf "$(command -v php)" /usr/local/modules/usr/bin/php && : > /etc/php/php.ini
install_app
wait_port 8084 30 && curl -s -m 5 $U/ | grep -q '<title>Login - Adminer</title>' && PID=$(cat /var/run/adminer.pid) \
    && tr '\0' ' ' < /proc/$PID/cmdline | grep -q '/usr/local/modules/usr/bin/php -c /etc/php/php.ini' \
    && pass "Adminer's login page on the NAS's own PHP ($(php -r 'echo PHP_VERSION;')), with its php.ini" || { fail "nas php: $(tail -n 5 /tmp/debug_apkg; tail -n 5 $D/adminer.log)"; exit 1; }
page_up adminer
ST=$(get status)
[ "$(echo "$ST" | j '$d["version"]')" = '"6.2.0"' ] && [ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["php"]')" = '"nas"' ] \
    && pass "the page: Adminer 6.2.0 answering, on the NAS's own PHP" || fail "status: $(echo "$ST" | head -c 300)"

echo "== Valkey, with its Redis driver plugin (on the NAS's own PHP)"
install_app valkey
wait_port 6379 30 || fail 'Valkey not answering'
VPW=$(awk '$1 == "requirepass" { print $2 }' $P/_valkey/valkey.conf)
REDISCLI_AUTH="$VPW" $P/valkey/binaries/valkey-cli -h 127.0.0.1 SET suite:greeting hello > /dev/null 2>&1
form; L=$(login wrong redis default 0); P2=$(curl -sL -m 10 -b $JAR -c $JAR "$U/?redis=127.0.0.1&username=default&db=0")
! echo "$P2" | grep -q 'Logout' && pass 'Valkey: a wrong password refused' || fail 'valkey: a wrong password logged in'
form; L=$(login "$VPW" redis default 0); P2=$(curl -sL -m 10 -b $JAR -c $JAR "$U/?redis=127.0.0.1&username=default&db=0")
echo "$P2" | grep -q 'Logout' && curl -sL -m 10 -b $JAR "$U/?redis=127.0.0.1&username=default&db=0&select=data" | grep -q 'suite:greeting' \
    && pass "Valkey: logged in as default with its password (System: Redis), its key seen ($(echo "$P2" | grep -o '<title>[^<]*</title>' | head -n 1))" \
    || fail "valkey login: redirect '$L' $(echo "$P2" | grep -o '<title>[^<]*</title>' | head -n 1)"

echo "== with PostgreSQL and the PHP app's PHP"
install_app postgresql
wait_port 5432 60 && pass 'PostgreSQL answering' || { fail "PostgreSQL: $(tail -n 5 /tmp/start.log)"; exit 1; }
page_up postgresql; PGPW=$(post password | j '$d["password"]' | tr -d '"')
mkdir -p $P/php && tar -xzf /pkg/php.tar.gz -C $P/php ./binaries/php
page_up adminer; post restart > /dev/null
wait_port 8084 30 && curl -s -m 5 $U/ | grep -q '<title>Login - Adminer</title>' && PID=$(cat /var/run/adminer.pid) \
    && tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$P/php/binaries/php -n" && [ "$(get status | j '$d["php"]')" = '"app"' ] \
    && pass "restarted from the page: on the PHP app's PHP now (no php.ini)" || { fail "app php: $(tail -n 10 /tmp/debug_apkg; cat $D/adminer.log)"; exit 1; }

echo '== its user, its workers, where it listens'
PID=$(cat /var/run/adminer.pid)
WORKERS=$(for p in /proc/[0-9]*; do [ "$(awk '{ print $4 }' $p/stat 2>/dev/null)" = "$PID" ] && echo "${p#/proc/}"; done | wc -l)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 88 ] && [ "$WORKERS" = 4 ] && [ "$(stat -c '%U %a' $D/sessions)" = 'adminer 700' ] \
    && [ "$(stat -c '%U %G %a' $D/htpasswd)" = 'root share 640' ] && pass "PHP's server as its own user (88), with 4 workers; its sessions its own, its htpasswd file Nginx's group's only" \
    || fail "users: uid $(awk '/^Uid:/ { print $2 }' /proc/$PID/status), $WORKERS workers, $(stat -c '%n %U %G %a' $D/sessions $D/htpasswd)"
# Whether it listens on every address: 0.0.0.0, or :: (IPv4 too)
everywhere() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F94") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -q "^00000000:\|^00000000000000000000000000000000:"; }
[ "$(grep '^LISTEN=' $D/settings)" = LISTEN=all ] && everywhere \
    && [ "$(get status | j '$d["listen"]')" = '"all"' ] && pass 'without the Nginx app: on the network by default (port 8084)' || fail "default: $(cat $D/settings)"
R=$(post listen -d listen=local); sleep 1
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! everywhere \
    && wait_port 8084 20 && pass 'only through the Nginx app: on the NAS itself only (127.0.0.1)' || fail "local: $R $(awk 'NR > 1 && $4 == "0A" && index($2, ":1F94")' /proc/net/tcp)"
PID=$(cat /var/run/adminer.pid)

echo "== a PostgreSQL login on Adminer's form"
form
L=$(login wrong); P2=$(curl -sL -m 10 -b $JAR -c $JAR "$U/?pgsql=127.0.0.1&username=postgres&db=postgres")
[ -n "$TOKEN" ] && ! echo "$P2" | grep -q 'Logout' && pass 'a wrong PostgreSQL password: not logged in' || fail 'wrong password logged in'
form
L=$(login "$PGPW"); P2=$(curl -sL -m 10 -b $JAR -c $JAR "$U/?pgsql=127.0.0.1&username=postgres&db=postgres")
echo "$P2" | grep -q 'Logout' && echo "$P2" | grep -q 'PostgreSQL' && pass "logged in to PostgreSQL ($(echo "$P2" | grep -o '<title>[^<]*</title>' | head -n 1))" \
    || fail "login: redirect '$L', then: $(curl -s -m 10 -b $JAR -o /dev/null -w '%{http_code} %{size_download}B' "$U/?pgsql=127.0.0.1&username=postgres&db=postgres") $(echo "$P2" | head -c 300) log: $(tail -n 4 $D/adminer.log | tr '\n' ' ')"
ls $D/sessions | grep -q '^sess_' && pass 'its session in its own folder' || fail "sessions: $(ls -la $D/sessions)"

echo "== its site's password"
R=$(post set_password -d password=short); echo "$R" | grep -q '12-128' && pass 'a short password refused' || fail "short: $R"
NEW=$(post set_password -d password= | j '$d["password"]' | tr -d '"'); H=$(cut -d: -f2- $D/htpasswd)
[ ${#NEW} = 20 ] && [ "$(php -r 'echo crypt($argv[1], $argv[2]) === $argv[2] ? "ok" : "no";' "$NEW" "$H")" = ok ] \
    && pass 'a generated password, in the htpasswd file (SHA-512 crypt)' || fail "new password: $NEW"

echo "== without the extra password (only the databases' own logins)"
R=$(post auth -d auth=)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! grep -q auth_file $P/adminer/nginx.json && grep -q '"uploads": true' $P/adminer/nginx.json \
    && [ "$(get status | j '$d["auth"]')" = false ] && php -r 'exit(json_decode(file_get_contents($argv[1])) ? 0 : 1);' $P/adminer/nginx.json \
    && pass 'switched off: its nginx.json without the password file (still valid, uploads kept)' || fail "auth off: $R $(cat $P/adminer/nginx.json)"
R=$(post auth -d auth=1)
grep -q '"auth_file": "_adminer/htpasswd"' $P/adminer/nginx.json && [ "$(get status | j '$d["auth"]')" = true ] \
    && pass 'switched on again: the password file back in its nginx.json' || fail "auth on: $R $(cat $P/adminer/nginx.json)"

echo '== stopping, removal'
sh $P/adminer/stop.sh $P/adminer > /dev/null 2>&1; sleep 1
! ps -e -o args 2>/dev/null | grep -q '[-]S 127.0.0.1:8084' && ! listening 8084 && pass "stopped: PHP's server and its workers" || fail "still running: $(ps -e -o pid,args | grep 8084)"
finish_app
