#!/bin/sh
# The Nginx app from its package, in a stand-in for the NAS, with stand-ins for what it proxies to (the NAS's dashboard
# on port 80, Navidrome on 4533, Calibre-Web on 8083 - each answering with what it received) and the PHP app's php-fpm:
# its first start (a self-signed certificate), the management page's API (apps, the domain's home app, user sites with
# PHP, its own certificate, a configuration error), what requests reach the apps with, apps added by other apps, sites
# declared by the apps (nginx.json) and the Store's recipes (recipe.json), stopping
P=/mnt/HD/HD_a2/Nas_Prog; D=$P/_nginx; DOMAIN=nas.example.test
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in sh adduser addgroup ps ip; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:$PATH
mkdir -p $P/_install/nginx /mnt/HD/HD_a2/Public /var/spool/cron/crontabs /var/www/apps && touch /var/spool/cron/crontabs/root
# Apps for it to find (their folders), and the PHP app's php-fpm (its binaries only: WD's own PHP isn't swapped here)
mkdir -p $P/navidrome $P/calibre-web $P/php/binaries
# Navidrome with its own page in the dashboard (CenterType 1) and an icon: a Configure link and its icon on the start page
mkdir -p $P/navidrome/web && printf 'Package:\t\tnavidrome\nIcon:\t\t\tnavidrome.svg\nAddonIndexPage:\tindex.php\nCenterType:\t\t1\n' > $P/navidrome/apkg.rc
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>' > $P/navidrome/web/navidrome.svg
tar -xzf /pkg/php.tar.gz -C /tmp ./binaries/php-fpm && mv /tmp/binaries/php-fpm $P/php/binaries/
# Stand-ins for the apps: each answers with its name, then what it received (method, path, headers, body size)
cat > /tmp/backend.py <<'EOF'
import http.server, json, sys
name, port = sys.argv[1], int(sys.argv[2])
class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self):
        # The dashboard's pages are HTML (the Nginx app adds its script to them)
        if name == "dashboard" and self.path.endswith(".html"):
            body = b"<!doctype html><html><head><title>NAS</title></head><body>dashboard</body></html>"
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
            return
        size = int(self.headers.get("Content-Length") or 0)
        received = 0
        while received < size:
            received += len(self.rfile.read(min(65536, size - received)))
        body = json.dumps({"app": name, "method": self.command, "path": self.path, "headers": dict(self.headers), "received": received}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_PUT = answer
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
for b in 'dashboard 80' 'navidrome 4533' 'calibre-web 8083'; do (python3 /tmp/backend.py $b > /dev/null 2>&1 &); done

echo '== installed and started (a self-signed certificate)'
tar -xzf /pkg/nginx.tar.gz -C $P/_install/nginx
cd $P && sh $P/_install/nginx/install.sh $P/_install/nginx $P > /tmp/install.log 2>&1 && sh $P/nginx/init.sh $P/nginx > /tmp/init.log 2>&1 && sh $P/nginx/start.sh $P/nginx > /tmp/start.log 2>&1

for i in $(seq 1 20); do curl -sk -o /dev/null https://127.0.0.1/ && break; sleep 1; done
SUBJECT=$(echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null | tr '\n' ' ')
[ -n "$SUBJECT" ] && pass "answering on 443 with its temporary self-signed certificate: $SUBJECT" || { fail "not answering: $(tail -n 10 /tmp/start.log /tmp/debug_apkg $D/logs/error.log 2>/dev/null)"; exit 1; }

# The management page, as the dashboard calls it (an admin's WD session, the page's CSRF token)
echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
(php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &)
sleep 1
B=http://127.0.0.1:8080/apps/nginx; CK='Cookie: PHPSESSID=adminsession123'
T=$(curl -s -H "$CK" $B/index.php | sed -n 's/.*let csrf *= "\([^"]*\)".*/\1/p')
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# A request to one of its sites by name (resolved to the NAS)
site() { n=$1; shift; curl -sk --resolve "$n:443:127.0.0.1" "$@" "https://$n/"; }
site_path() { n=$1; p=$2; shift 2; curl -sk --resolve "$n:443:127.0.0.1" "$@" "https://$n$p"; }

ST=$(get status)
[ "$(echo "$ST" | j '$d["running"]')" = true ] && [ "$(echo "$ST" | j '$d["config_ok"]')" = true ] && echo "$ST" | j 'array_column($d["apps"], "app", "name")' | grep -q '"navidrome":"navidrome"' \
    && pass "page status: running $(echo "$ST" | j '$d["version"]'), configuration OK, PHP $(echo "$ST" | j '$d["php"]["version"]') available, apps found: $(echo "$ST" | j 'implode(",", array_column($d["apps"], "name"))')" || fail "status: $(echo "$ST" | cut -c1-300)"
[ "$(code -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=status")" = 403 ] && [ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d 'apps=[]' "$B/api.php?action=save_apps")" = 403 ] \
    && pass 'page: refused without a NAS login, or with a wrong CSRF token' || fail 'page auth'

echo '== the domain, its apps'
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $D/apps.json $DOMAIN
APPS=$(get status | j '$d["apps"]')
R=$(post save_apps --data-urlencode "apps=$APPS" -d home=gui)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ls $D/sites | grep -q '60-app-navidrome.conf' && pass "apps saved: their sites written and Nginx reloaded ($(ls $D/sites | tr '\n' ' '))" || fail "save_apps: $R"
M=$(site navidrome.$DOMAIN)
[ "$(echo "$M" | j '$d["app"]')" = '"navidrome"' ] && pass "navidrome.$DOMAIN reaches Navidrome" || fail "navidrome: $M"
[ "$(echo "$M" | j '$d["headers"]["Host"]')" = "\"navidrome.$DOMAIN\"" ] && [ "$(echo "$M" | j '$d["headers"]["X-Forwarded-Proto"]')" = '"https"' ] \
    && [ "$(echo "$M" | j '$d["headers"]["X-Real-IP"]')" = '"127.0.0.1"' ] && [ "$(echo "$M" | j '$d["headers"]["X-Forwarded-Host"]')" = "\"navidrome.$DOMAIN\"" ] \
    && pass "...with its name (Host), https (X-Forwarded-Proto), the visitor's address (X-Real-IP) and X-Forwarded-Host" || fail "headers: $(echo "$M" | j '$d["headers"]')"
[ "$(site $DOMAIN | j '$d["app"]')" = '"dashboard"' ] && pass "$DOMAIN itself shows the home app (the NAS's dashboard)" || fail "home: $(site $DOMAIN | head -c 200)"
site apps.$DOMAIN | grep -q "navidrome.$DOMAIN" && site unknown.$DOMAIN | grep -q "navidrome.$DOMAIN" \
    && pass "the start page (apps.$DOMAIN) lists the apps; any other name gets it too, never an app" || fail "start page: $(site apps.$DOMAIN | head -c 300)"
S=$(site apps.$DOMAIN)
echo "$S" | grep -q "href=\"https://$DOMAIN/#configure=navidrome/index.php\"" && echo "$S" | grep -q 'src="icons/navidrome.svg"' \
    && [ "$(site_path apps.$DOMAIN /icons/navidrome.svg -o /dev/null -w '%{http_code}')" = 200 ] && ! echo "$S" | grep -q 'configure=calibre-web' \
    && echo "$S" | grep -q "class=\"dashboard\" href=\"https://$DOMAIN/\"" && ! echo "$S" | grep -q '<strong>NAS dashboard</strong>' \
    && pass "the start page: Navidrome's icon, and its Configure link (the dashboard's address, #configure=navidrome/index.php) - none for an app without a page of its own; the dashboard in its header, not a card" \
    || fail "start page links: $(echo "$S" | grep -o 'href="[^"]*"\|src="[^"]*"' | tr '\n' ' ')"
H=$(site_path $DOMAIN /home.html --compressed); E=$(site $DOMAIN --compressed | j '$d["headers"]["Accept-Encoding"] ?? "none"')
echo "$H" | grep -q '<script src="/nginx-app-dashboard.js"></script></head>' && [ "$E" = '"none"' ] \
    && site_path $DOMAIN /nginx-app-dashboard.js | grep -q 'configure=' && ! grep -q sub_filter $D/sites/60-app-navidrome.conf \
    && pass "the dashboard's pages get the script that opens Configure links (pages asked for uncompressed; only the dashboard's site)" \
    || fail "dashboard script: $H / Accept-Encoding $E / $(site_path $DOMAIN /nginx-app-dashboard.js | head -c 100)"
[ "$(curl -sk --http2 -o /dev/null -w '%{http_version}' --resolve navidrome.$DOMAIN:443:127.0.0.1 https://navidrome.$DOMAIN/)" = 2 ] && pass 'HTTP/2' || fail 'no HTTP/2'
grep -q 'client_max_body_size    0' $D/sites/60-app-books.conf && grep -q 'proxy_buffering         off' $D/sites/60-app-navidrome.conf \
    && [ "$(head -c 64000000 /dev/zero | site books.$DOMAIN -X POST --data-binary @- -H 'Content-Type: application/octet-stream' | j '$d["received"]')" = 64000000 ] \
    && pass 'uploads (Calibre-Web: no size limit - a 64MB upload passed through) and streaming (Navidrome: not buffered) as each app needs' || fail "options: $(grep -h 'client_max\|buffering' $D/sites/60-app-books.conf $D/sites/60-app-navidrome.conf)"

for bad in '[{"name":"Bad Name","target":"http://127.0.0.1:1","enabled":true}]' '[{"name":"x","target":"ftp://127.0.0.1:1","enabled":true}]' \
    '[{"name":"x","target":"http://127.0.0.1:1","enabled":true},{"name":"x","target":"http://127.0.0.1:2","enabled":true}]'; do
    R=$(post save_apps --data-urlencode "apps=$bad" -d home=); [ "$(echo "$R" | j '$d["ok"]')" = false ] || fail "allowed: $bad"
done

[ "$(site navidrome.$DOMAIN | j '$d["app"]')" = '"navidrome"' ] && pass "refused (and nothing changed): a bad name, a target that isn't http(s), a name used twice" || fail 'a refused save changed something'

echo "== apps added by other apps (as the Store adds a recipe's site)"
(python3 /tmp/backend.py hello 18081 > /dev/null 2>&1 &); sleep 1
php $P/nginx/lib/sites.php add-app $D hello http://127.0.0.1:18081 'Hello' --stream > /tmp/add.log 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ "$(site hello.$DOMAIN | j '$d["app"]')" = '"hello"' ] && [ "$(php $P/nginx/lib/sites.php url $D hello)" = "https://hello.$DOMAIN/" ] \
    && pass "add-app: hello.$DOMAIN reaches it, and its address is known" || fail "add-app: $(cat /tmp/add.log) $(site hello.$DOMAIN | head -c 200)"
php $P/nginx/lib/sites.php add-app $D hello http://127.0.0.1:18081 'Hello' --start=/admin/ > /tmp/add.log 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ "$(site_path hello.$DOMAIN /api/auth | j '$d["path"]')" = '"/api/auth"' ] && [ "$(site hello.$DOMAIN -o /dev/null -w '%{http_code} %{redirect_url}')" = "302 https://hello.$DOMAIN/admin/" ] \
    && [ "$(php $P/nginx/lib/sites.php url $D hello)" = "https://hello.$DOMAIN/admin/" ] \
    && pass "add-app --start: / goes to /admin/, other paths still reach it (e.g. Pi-hole's /api)" || fail "add-app --start: $(cat /tmp/add.log) $(site_path hello.$DOMAIN /api/auth | head -c 200)"
php $P/nginx/lib/sites.php add-app $D navidrome http://127.0.0.1:9 > /tmp/add2.log 2>&1 && fail 'another app took the name navidrome' || pass "a name used for another target refused: $(head -n 1 /tmp/add2.log)"
php $P/nginx/lib/sites.php remove-app $D hello > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ ! -f $D/sites/60-app-hello.conf ] && ! site hello.$DOMAIN | grep -q '"app": "hello"' && pass 'remove-app: its site gone' || fail 'remove-app'

echo "== sites declared by the apps (nginx.json) and the Store's recipes (their recipe.json)"
mkdir -p $P/hello $P/_recipe/.store/recipe
printf '{"name": "hi", "label": "Hello app", "target": "http://127.0.0.1:18081", "uploads": true}\n' > $P/hello/nginx.json
printf '{"name": "Recipe", "web": {"port": 18081, "path": "/admin/", "nginx": {"name": "rcp", "stream": true}, "sites": [{"name": "rcp-two", "label": "Its second app", "port": 18081}, {"name": "rcp-opt", "port": 18081, "if": "OPTIONAL"}]}}\n' > $P/_recipe/.store/recipe/recipe.json
echo '{"values": {"OPTIONAL": false}}' > $P/_recipe/.store/installed.json
php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ "$(site hi.$DOMAIN | j '$d["app"]')" = '"hello"' ] && grep -q 'client_max_body_size    0' $D/sites/60-app-hi.conf \
    && [ "$(site_path rcp.$DOMAIN /api/auth | j '$d["path"]')" = '"/api/auth"' ] && [ "$(site rcp.$DOMAIN -o /dev/null -w '%{http_code} %{redirect_url}')" = "302 https://rcp.$DOMAIN/admin/" ] \
    && grep -q 'proxy_buffering         off' $D/sites/60-app-rcp.conf \
    && [ "$(site rcp-two.$DOMAIN | j '$d["app"]')" = '"hello"' ] && [ ! -f $D/sites/60-app-rcp-opt.conf ] \
    && pass "an app's nginx.json and a recipe's web block each give it its site, with their options (a recipe opens at its path, every path passed on); a recipe's other sites too, an optional one only when switched on" \
    || fail "declared: $(ls $D/sites | tr '\n' ' ') $(site_path rcp.$DOMAIN /api/auth | head -c 200)"
echo '{"id": "my-recipe", "values": {"OPTIONAL": true}}' > $P/_recipe/.store/installed.json; php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ "$(site rcp-opt.$DOMAIN | j '$d["app"]')" = '"hello"' ] && pass 'the optional one once its setting is on' || fail "optional recipe site: $(ls $D/sites | tr '\n' ' ')"
S=$(site apps.$DOMAIN)
echo "$S" | grep -q "<h2>Recipe <a class=\"configure\" href=\"https://$DOMAIN/#recipe=my-recipe\"" && [ "$(echo "$S" | grep -c '#recipe=')" = 1 ] \
    && echo "$S" | grep -q '<strong>Rcp</strong>' && echo "$S" | grep -q '<strong>Its second app</strong>' \
    && pass "the start page: the recipe's sites together under its name, with one Configure link to its page in the Store (#recipe=my-recipe)" || fail "recipe links: $(site apps.$DOMAIN | grep -o 'href="[^"]*recipe[^"]*"')"
APPS=$(get status | j '$d["apps"]' | php -r '$a=json_decode(stream_get_contents(STDIN),true); foreach ($a as &$x) { if (isset($x["app"]) && $x["app"]==="hello") { $x["name"]="hey"; $x["label"]="Hey"; $x["target"]="http://127.0.0.1:9"; $x["uploads"]=false; } } echo json_encode($a);')
R=$(post save_apps --data-urlencode "apps=$APPS" -d home=gui)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(site hey.$DOMAIN | j '$d["app"]')" = '"hello"' ] && grep -q 'client_max_body_size    0' $D/sites/60-app-hey.conf && [ ! -f $D/sites/60-app-hi.conf ] \
    && pass "the page renames a declared app, but can't change what its app set (target, options)" || fail "declared save: $R $(cat $D/sites/60-app-hey.conf 2>/dev/null | grep proxy_pass)"
php $P/nginx/lib/sites.php remove-app $D hey > /dev/null 2>&1; [ -f $D/sites/60-app-hey.conf ] && pass "remove-app leaves a declared app's site (its app decides)" || fail 'remove-app removed a declared site'
mv $P/hello /tmp/hello.app; rm $P/_recipe/.store/installed.json
php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ ! -f $D/sites/60-app-hey.conf ] && [ ! -f $D/sites/60-app-rcp.conf ] && ! get status | grep -q '"hey"' && pass 'their sites go with the app and the recipe' || fail "not removed: $(ls $D/sites | tr '\n' ' ')"
mv /tmp/hello.app $P/hello; php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1
[ -f $D/sites/60-app-hey.conf ] && [ "$(get status | j 'array_column($d["apps"], "label", "app")["hello"]')" = '"Hey"' ] && pass 'reinstalled: back under the name and label chosen' || fail "reinstall: $(ls $D/sites | tr '\n' ' ')"
# An app asking for a password through Nginx: its htpasswd file (SHA-512 crypt, as the apps write it), Nginx's group's
# only
mkdir -p $P/_hello; printf '{"name": "locked", "target": "http://127.0.0.1:18081", "auth_file": "_hello/htpasswd"}\n' > $P/hello/nginx.json
php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1
[ "$(site hey.$DOMAIN -o /dev/null -w '%{http_code}')" = 401 ] && ! site hey.$DOMAIN -u admin:anything | grep -q '"app"' && [ "$(site hey.$DOMAIN -u admin:anything -o /dev/null -w '%{http_code}')" != 200 ] \
    && pass "a password file missing: refused without a password (401) and with one ($(site hey.$DOMAIN -u admin:anything -o /dev/null -w '%{http_code}')) - nothing passed on" || fail "no password file: $(site hey.$DOMAIN -u admin:anything -o /dev/null -w '%{http_code}')"
php -r 'echo "admin:" . crypt("Right-pass-123", "\$6\$rounds=5000\$" . bin2hex(random_bytes(8)) . "\$") . "\n";' > $P/_hello/htpasswd
chown root:nogroup $P/_hello/htpasswd; chmod 640 $P/_hello/htpasswd
[ "$(site hey.$DOMAIN -o /dev/null -w '%{http_code}')" = 401 ] && [ "$(site hey.$DOMAIN -u admin:wrong -o /dev/null -w '%{http_code}')" = 401 ] \
    && [ "$(site hey.$DOMAIN -u admin:Right-pass-123 | j '$d["app"]')" = '"hello"' ] \
    && pass "a site asking for a password (the app's htpasswd, root:nogroup 640): none or a wrong one refused (401), the right one passed on" \
    || fail "auth: $(site hey.$DOMAIN -o /dev/null -w '%{http_code}') $(site hey.$DOMAIN -u admin:Right-pass-123 | head -c 200) $(grep auth $D/sites/60-app-hey.conf)"
printf '{"name": "locked", "target": "http://127.0.0.1:18081", "auth_file": "../etc/passwd"}\n' > $P/hello/nginx.json; php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1
[ ! -f $D/sites/60-app-hey.conf ] && pass "a password file outside the apps' data folders refused (the declaration ignored)" || fail "auth_file outside Nas_Prog/_*: $(grep auth $D/sites/60-app-hey.conf)"
rm -rf $P/_hello
printf '{"name": "Bad name", "target": "file:///etc"}\n' > $P/hello/nginx.json; php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1
[ ! -f $D/sites/60-app-hey.conf ] && pass "a declaration that isn't valid is ignored" || fail 'bad nginx.json used'
rm -rf $P/hello $P/_recipe; php $P/nginx/lib/sites.php generate $D > /dev/null 2>&1 && sh $P/nginx/nginx_ctl.sh reload > /dev/null 2>&1

echo '== user sites (a static one, one with PHP)'
mkdir -p /mnt/HD/HD_a2/Public/site /mnt/HD/HD_a2/Public/phpsite
echo '<h1>static</h1>' > /mnt/HD/HD_a2/Public/site/index.html; echo '<?php echo "secret";' > /mnt/HD/HD_a2/Public/site/x.php
echo '<?php echo "PHP " . PHP_VERSION . " " . php_sapi_name();' > /mnt/HD/HD_a2/Public/phpsite/index.php
chmod -R a+rX /mnt/HD/HD_a2/Public
R=$(post save_sites --data-urlencode 'sites=[{"name":"static","root":"/mnt/HD/HD_a2/Public/site","php":false,"enabled":true},{"name":"dynamic","root":"/mnt/HD/HD_a2/Public/phpsite","php":true,"enabled":true}]')
[ "$(echo "$R" | j '$d["ok"]')" = true ] && site static.$DOMAIN | grep -q static && pass 'a static site served' || fail "save_sites: $R"
X=$(site_path static.$DOMAIN /x.php -w ' %{http_code}')
! echo "$X" | grep -q secret && pass "a .php file in a site without PHP: neither run nor shown ($(echo "$X" | tail -c 4))" || fail "php source shown: $X"

for i in $(seq 1 10); do site dynamic.$DOMAIN | grep -q '^PHP 8' && break; sleep 1; done
site dynamic.$DOMAIN | grep -q '^PHP 8.* fpm-fcgi' && pass "a PHP site, through the PHP app's php-fpm: $(site dynamic.$DOMAIN)" || fail "php site: $(site dynamic.$DOMAIN | head -c 200); $(tail -n 3 $D/logs/error.log)"
post save_sites --data-urlencode 'sites=[{"name":"navidrome","root":"/mnt/HD/HD_a2/Public/site","enabled":true}]' | grep -q 'already uses this name' && pass "a site can't take an app's name" || fail 'site name clash'

echo '== its own certificate'
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem -out /tmp/c.pem -days 30 -subj "/CN=*.$DOMAIN" 2> /dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k2.pem -out /tmp/c2.pem -days 30 -subj '/CN=other' 2> /dev/null
post own_certificate --data-urlencode "certificate=$(cat /tmp/c.pem)" --data-urlencode "key=$(cat /tmp/k2.pem)" | grep -q "doesn't belong" && pass "a certificate with another's key refused" || fail 'mismatched key accepted'
R=$(post own_certificate --data-urlencode "certificate=$(cat /tmp/c.pem)" --data-urlencode "key=$(cat /tmp/k.pem)")
SERVED=$(echo | openssl s_client -connect 127.0.0.1:443 -servername navidrome.$DOMAIN 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
echo "$SERVED" | grep -q "\*.$DOMAIN" && [ "$(stat -c %a $D/certs/default.key)" = 600 ] && pass "its own certificate served ($SERVED), its key root's only" || fail "own certificate: $R / $SERVED"

echo '== a configuration error'
echo 'this is not nginx' > $D/sites/90-mine.conf
R=$(post reload -d confirm=1)
[ "$(echo "$R" | j '$d["ok"]')" = false ] && [ "$(get status | j '$d["config_ok"]')" = false ] && [ "$(site navidrome.$DOMAIN | j '$d["app"]')" = '"navidrome"' ] \
    && pass "a broken file of the user's: reload refused with the error, Nginx carries on with the previous configuration" || fail "broken config: $R"
rm -f $D/sites/90-mine.conf; post reload -d confirm=1 > /dev/null

echo '== stopping'
sh $P/nginx/stop.sh $P/nginx > /dev/null 2>&1; sleep 2
[ "$(code -k https://127.0.0.1/)" = 000 ] && pass 'stopped' || fail 'still answering'
