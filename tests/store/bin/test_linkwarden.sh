# The real Linkwarden recipe through the Store: its three containers, published on the NAS itself only, the admin
# account from the wizard (made by its post_install hook - and not another, and no sign-ups), its address from the
# Nginx app's site (site.env), the admin's password kept out of the containers, a saved page archived (a screenshot and
# a PDF, by its own Chromium - it needs the internet), its Nginx site, removal
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url="$(php -r 'require $argv[1]; echo STORE_DEFAULT_REPO;' $P/store/lib/store.php)" >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
python3 /tbin/repotool.py add-recipe /www/repo $PROJ/recipes/linkwarden; post refresh >/dev/null
D=$P/_linkwarden
L=http://127.0.0.1:3003
get details "&kind=recipes&repo=$REPO&id=linkwarden" >/dev/null
echo "  problems: $(j '$d["problems"]')"
ANS='{"ADMIN_USERNAME":"admin","ADMIN_PASSWORD":"Test-pass-123"}'
post start -d job=recipe_install -d repo=$REPO -d id=linkwarden --data-urlencode "answers=$ANS" >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && pass "Linkwarden installed through the Store: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG"; get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | tail -30; }

# Logs in through its API (as its apps do): prints the session's token (empty if refused) - $1 user, $2 password
session() { curl -s -m 30 -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"$2\",\"sessionName\":\"test\"}" $L/api/v1/session \
    | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["response"]["token"] ?? "";'; }

for c in linkwarden linkwarden_postgres linkwarden_meilisearch; do printf '  %s: %s\n' $c "$(docker inspect -f '{{.State.Status}}' $c 2>&1)"; done
[ "$(docker port linkwarden 3000/tcp 2>/dev/null)" = '127.0.0.1:3003' ] && [ "$(stat -c '%a' $D/.env)" = 600 ] \
    && sed -n 's/^NEXTAUTH_SECRET=\(.*\)/\1/p' $D/.env | grep -qE '^[A-Za-z0-9]{48}$' \
    && pass 'published on the NAS itself only (127.0.0.1:3003); its .env root'"'"'s only, its secrets generated' || fail "port: $(docker port linkwarden 2>&1); $(ls -la $D)"
grep -qx 'NEXTAUTH_URL=https://links.nas.example.test/api/v1/auth' $D/site.env && docker exec linkwarden printenv NEXTAUTH_URL | grep -qx 'https://links.nas.example.test/api/v1/auth' \
    && pass 'its address from the Nginx app'"'"'s site (https://links.nas.example.test, in site.env and its container)' || fail "address: $(cat $D/site.env 2>&1)"
ENVS=$(docker inspect -f '{{json .Config.Env}}' linkwarden linkwarden_postgres linkwarden_meilisearch 2>/dev/null)
[ "$(echo "$ENVS" | grep -c MEILI_MASTER_KEY)" = 2 ] && ! echo "$ENVS" | grep -q 'Test-pass-123' \
    && pass 'the admin'"'"'s password kept out of the containers' || fail 'the admin password is in a container'

echo '== its admin, no one else'
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' $L/login)" = 200 ] && break; sleep 3; done
TOKEN=$(session admin Test-pass-123)
[ -n "$TOKEN" ] && [ -z "$(session admin wrong-password)" ] && pass 'the wizard'"'"'s admin logs in (a wrong password refused)' || fail "admin: $(docker logs linkwarden 2>&1 | tail -n 5)"
R=$(curl -s -m 30 -H 'Content-Type: application/json' -d '{"name":"Mallory","username":"mallory","password":"Mallory-pass-1"}' $L/api/v1/users)
echo "$R" | grep -q 'Registration is disabled' && [ "$(docker exec linkwarden printenv NEXT_PUBLIC_DISABLE_REGISTRATION)" = true ] \
    && [ "$(docker exec linkwarden_postgres psql -U postgres -qAt -c 'SELECT count(*) FROM "User"')" = 1 ] \
    && pass 'sign-ups off (nobody signs themselves up): one account' || fail "sign-up: $R"

echo '== a saved page'
ID=$(curl -s -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"url":"https://example.com/"}' $L/api/v1/links \
    | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["response"]["id"] ?? "";')
[ -n "$ID" ] && pass "a link saved (id $ID)" || fail 'link'
for i in $(seq 1 60); do
    LINK=$(curl -s -m 30 -H "Authorization: Bearer $TOKEN" $L/api/v1/links/$ID)
    echo "$LINK" | php -r '$d=json_decode(stream_get_contents(STDIN),true)["response"] ?? []; exit(!empty($d["image"]) && !empty($d["pdf"]) ? 0 : 1);' && break
    sleep 5
done
echo "$LINK" | php -r '$d=json_decode(stream_get_contents(STDIN),true)["response"] ?? []; exit(!empty($d["image"]) && $d["image"] !== "unavailable" && !empty($d["pdf"]) && $d["pdf"] !== "unavailable" ? 0 : 1);' \
    && [ -f "$D/data/archives/1/$ID.pdf" ] \
    && pass 'the page archived by its own Chromium: a screenshot and a PDF (in its data folder)' || fail "archive: $(echo "$LINK" | head -c 400)"

SITE=$P/_nginx/sites/60-app-links.conf
grep -q 'proxy_pass *http://127.0.0.1:3003' $SITE 2>/dev/null && grep -q 'client_max_body_size    0' $SITE \
    && pass 'Nginx links site (uploads)' || fail "nginx: $(ls $P/_nginx/sites 2>&1)"

echo '== removed'
post start -d job=recipe_uninstall -d id=linkwarden -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -z "$(docker ps -aq --filter name=^linkwarden)" ] && pass "removed: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG"
true
