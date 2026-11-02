# The real Immich recipe through the Store (a copy without the GPU device and with a lower disk requirement, made by
# run_tests.sh): containers healthy, face recognition off, existing photos mounted read only, the Nginx site, removal
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
mkdir -p $V/Photos "$V/Family/Old Photos/2019"; cp /tfix/photo.jpg "$V/Family/Old Photos/2019/a.jpg"
python3 /tbin/repotool.py add-recipe /www/repo /tfix/immich-small; post refresh >/dev/null
D=$P/_immich
get details "&kind=recipes&repo=$REPO&id=immich" >/dev/null
echo "  problems: $(j '$d["problems"]')"; echo "  wizard: $(j 'implode(", ", array_map(function($f){return $f["key"].(empty($f["advanced"])?"":"(adv)")."=".json_encode($f["value"]);}, $d["wizard"]))' | cut -c1-600)"
ANS='{"UPLOAD_LOCATION":"'$V'/Photos/Immich","EXTERNAL_PHOTOS":["'"$V/Family/Old Photos"'"],"FACIAL_RECOGNITION":false,"TZ":"Europe/London","IMMICH_VERSION":"v3"}'
post start -d job=recipe_install -d repo=$REPO -d id=immich --data-urlencode "answers=$ANS" >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && pass "Immich installed through the Store: $JOB_MSG" || { fail "immich: $JOB_STATE $JOB_MSG"; get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | tail -30; }

for c in immich_server immich_machine_learning immich_postgres immich_redis; do printf '  %s: %s\n' $c "$(docker inspect -f '{{.State.Health.Status}}' $c 2>&1)"; done
docker exec immich_postgres psql -qAt -U postgres -d immich -c "SELECT value FROM system_metadata WHERE key='system-config'" | grep -q '"enabled": false' && pass 'face recognition off (post_install hook)' || fail "face: $(docker exec immich_postgres psql -qAt -U postgres -d immich -c "SELECT value FROM system_metadata" 2>&1)"
docker exec immich_server ls '/external/Family/Old Photos/2019' | grep -q a.jpg && docker exec immich_server sh -c 'touch "/external/Family/Old Photos/x" 2>&1' | grep -q 'Read-only' && pass 'existing photos mounted read only at /external/Family/Old Photos' || fail 'external'
grep -q 'client_max_body_size    0' $P/_nginx/sites/60-app-photos.conf && pass 'Nginx photos site with uploads' || fail 'nginx photos'
sed -n 's/^DB_PASSWORD=\(.*\)/\1/p' $D/.env | grep -qE '^[A-Za-z0-9]{32}$' && pass 'database password generated (32 letters/digits)' || fail 'db password'

for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:2283/api/server/ping | grep -q 200 && break; sleep 2; done
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:2283/api/server/ping | grep -q 200 && pass 'Immich answers on :2283' || fail 'ping'
get job >/dev/null; j '$d["log"]' | grep -i 'PHP warning' | head -3
post start -d job=recipe_uninstall -d id=immich -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -d $V/Photos/Immich ] && [ -f "$V/Family/Old Photos/2019/a.jpg" ] && [ -z "$(docker ps -aq --filter name=immich_)" ] && pass "removed; photos (kept by the recipe) and existing photos untouched: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG"
get details "&kind=recipes&repo=$REPO&id=immich" >/dev/null; true
