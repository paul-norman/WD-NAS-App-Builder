# Repositories, signatures and native apps: adding repositories (HTTPS only, third-party confirmation, a catalogue
# escaping its recipe refused), signed catalogues (tampering, key changes), and app installs/updates/removals through the
# stand-ins for WD's installer (redirects, checksums, plain-HTTP downgrades and other models refused)
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json; EVIL=https://evil.test:8443/store.json; EVIL2=https://evil.test:8443/two/store.json
echo "== repositories"
get catalogue >/dev/null; [ "$(j 'count($d["repos"])')" = 1 ] && [ "$(j '$d["repos"][0]["default"]')" = true ] && pass "fresh Store: the default repository listed ($(j '$d["repos"][0]["url"]'))" || fail "default: $(cat /tmp/body)"
post refresh >/dev/null; echo "  default repo refresh (no GitHub yet): $(j '$d["errors"][0]' | cut -c1-140)"
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null
[ "$(post add_repo -d url=http://repo.test/store.json -d confirm=1)" = 400 ] && pass "plain http refused: $(j '$d["error"]' | cut -c1-80)" || fail "http accepted"
[ "$(post add_repo -d url=$REPO)" = 400 ] && pass "third-party repo needs confirming" || fail "no confirm"
[ "$(post add_repo -d url=$REPO -d confirm=1)" = 200 ] && pass "test repo added: $(j '$d["name"]'), key $(j '$d["fingerprint"]')" || fail "add: $(cat /tmp/body)"
grep -q "releases\|packages" /tmp/server.log && fail "packages fetched while adding" || pass "adding only fetched store.json, its signature and icons"
get catalogue >/dev/null; echo "  catalogue: $(j 'count($d["apps"])') apps, $(j 'count($d["recipes"])') recipes, icons: $(j 'count(array_filter($d["apps"], function($a){return $a["icon"]!=="";}))'), nas: $(j '$d["nas"]')"
[ "$(post add_repo -d url=$EVIL -d confirm=1)" = 400 ] && pass "catalogue with a path escaping its recipe refused: $(j '$d["error"]' | cut -c1-120)" || fail "evil accepted"
[ "$(post add_repo -d url=$EVIL2 -d confirm=1)" = 200 ] && pass "second third-party repo (unsigned) added" || fail "evil2: $(cat /tmp/body)"
echo "== signatures"
python3 /tbin/repotool.py tamper /www/repo
post refresh >/dev/null; j '$d["errors"]' | grep -q "signature is not valid" && pass "changed store.json refused (signature): $(j '$d["errors"][0]' | cut -c1-110)" || fail "tamper: $(cat /tmp/body)"
get catalogue >/dev/null; [ "$(j 'count($d["apps"])')" -ge 28 ] && ! grep -q "Changed:" /tmp/body && pass "the previous catalogue is kept meanwhile" || fail "catalogue lost"
python3 /tbin/repotool.py sign /www/repo /tcerts/keyB.pem
post refresh >/dev/null; j '$d["errors"]' | grep -q "signing key has changed" && pass "new signing key refused until accepted" || fail "key change: $(cat /tmp/body)"
get catalogue >/dev/null; NEWFP=$(j '$d["repos"][0]["new_fingerprint"]' | tr -d '"'); [ "$(j '$d["repos"][0]["key_changed"]')" = true ] && pass "page shows the new key: $NEWFP" || fail "no key_changed"
[ "$(post accept_key -d url=$REPO -d fingerprint=00)" = 400 ] && pass "accepting needs the shown fingerprint" || fail "accept without fp"
[ "$(post accept_key -d url=$REPO -d fingerprint=$NEWFP)" = 200 ] && post refresh >/dev/null && [ "$(j 'count($d["errors"])')" = 0 ] && pass "new key accepted; refresh clean (Changed: text now signed = $(grep -c 'Changed:' /www/repo/store.json))" || fail "accept: $(cat /tmp/body)"
echo "== checking for new versions by itself"
get catalogue >/dev/null; [ "$(j '$d["stale"]')" = false ] && pass "just refreshed: not stale" || fail "stale after refresh"
for f in $V/Nas_Prog/_store/cache/*.status.json; do php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["checked"]=gmdate("Y-m-d\\TH:i:s\\Z", time()-7200); file_put_contents($f, json_encode($s));' "$f"; done
get catalogue >/dev/null; [ "$(j '$d["stale"]')" = true ] && pass "checked 2 hours ago: stale (the page refreshes by itself)" || fail "not stale"
STORE_TEST_VOLUME=$V php $P/store/lib/refresh.php; get catalogue >/dev/null; [ "$(j '$d["stale"]')" = false ] && pass "the daily check (lib/refresh.php) refreshed them" || fail "refresh.php"
echo "== an app made by someone else (publisher)"
python3 /tbin/repotool.py set-app /www/repo nano publisher '"Nano Makers"'; post refresh >/dev/null
get details "&kind=apps&repo=$REPO&id=nano" >/dev/null; [ "$(j '$d["publisher"]')" = '"Nano Makers"' ] && pass "publisher shown on its page" || fail "publisher: $(j '$d["publisher"]')"
get catalogue >/dev/null; [ "$(j 'array_values(array_filter($d["apps"], function($a){return $a["id"]==="nano";}))[0]["publisher"]')" = '"Nano Makers"' ] && pass "and on its card" || fail "card publisher"
echo "== native apps"
get details "&kind=apps&repo=$REPO&id=nano" >/dev/null; echo "  nano details: problems=$(j '$d["problems"]') replaces=$(j '$d["replaces"]') size=$(j '$d["size"]')"
post start -d job=app_install -d repo=$REPO -d id=nano >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ -f $P/nano/apkg.rc ] && [ "$(cat $P/nano/.installed_sha256)" = "$(sha256sum $PROJ/packages/nano/$(cat $PROJ/packages/nano/latest)/nano_*_MyCloudPR4100.bin | cut -d' ' -f1)" ] && pass "nano installed through upload_apkg ($JOB_MSG), package as built" || fail "nano: $JOB_STATE $JOB_MSG"
grep -q "upload_apkg nano_.*_MyCloudPR4100.bin (cwd /usr/local/apps_upload)" /tmp/wdtools.log && [ -z "$(ls -A /usr/local/apps_upload)" ] && pass "WD's installer called as the dashboard does; upload folder left empty" || fail "tools: $(cat /tmp/wdtools.log) $(ls -A /usr/local/apps_upload)"
grep -q "GET /releases/nano" /tmp/server.log && grep -q "GET /packages/nano" /tmp/server.log && pass "package download followed the release redirect" || fail "redirect: $(grep nano /tmp/server.log)"
get job >/dev/null; j '$d["log"]' | grep -q "SHA256 matches" && pass "log shows the checksum check" || fail "log: $(j '$d["log"]')"
get catalogue >/dev/null; echo "  nano in catalogue: $(j 'array_values(array_filter($d["apps"], function($a){return $a["id"]==="nano";}))[0]')" | cut -c1-300
[ "$(post start -d job=app_install -d repo=$REPO -d id=nano)" = 200 ] && job_wait && [ "$JOB_STATE" = '"failed"' ] && pass "installing again refused: $JOB_MSG" || fail "reinstall: $JOB_STATE"
post start -d job=app_install -d repo=$REPO -d id=python >/dev/null; job_wait; echo "  python install: $JOB_STATE $JOB_MSG"
python3 /tbin/repotool.py set-app /www/repo python version '"99.0"'; post refresh >/dev/null
get catalogue >/dev/null; [ "$(j 'array_values(array_filter($d["apps"], function($a){return $a["id"]==="python";}))[0]["update"]')" = true ] && pass "update offered (python 99.0)" || fail "no update"
post start -d job=app_update -d repo=$REPO -d id=python >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && grep -q "99.0" $P/python/apkg.rc && grep -q "del_apkg python" /tmp/wdtools.log && pass "python (keeps_data) updated by del_apkg + install: $JOB_MSG" || fail "update: $JOB_STATE $JOB_MSG"
# WD's list lagging behind an update (as it does after the Store updates itself): the app's own apkg.rc wins
sed -i 's#<name>python</name>\(.*\)<version>99.0</version>#<name>python</name>\1<version>3.0.1</version>#' /var/www/xml/apkg_all.xml
get catalogue >/dev/null; [ "$(j 'array_values(array_filter($d["apps"], function($a){return $a["id"]==="python";}))[0]["update"]')" = false ] \
	&& [ "$(j 'array_values(array_filter($d["installed_apps"], function($a){return $a["id"]==="python";}))[0]["version"]')" = '"99.0"' ] \
	&& grep -q '<version>3.0.1</version>' /var/www/xml/apkg_all.xml && pass "WD's list says 3.0.1, apkg.rc 99.0: shown as 99.0, no update offered" || fail "lagging list: $(grep -o '<name>python</name>.*</version>' /var/www/xml/apkg_all.xml)"
sh /tbin/apkg_xml.sh
echo "== a fork (the same apps, under the same name)"
FORK=https://evil.test:8443/fork/store.json; rm -rf /www/evil/fork; cp -r /www/repo /www/evil/fork; python3 /tbin/repotool.py set-app /www/evil/fork python version '"99.1"'
post add_repo -d url=$FORK -d confirm=1 >/dev/null; get catalogue >/dev/null
L='array_column($d["repos"], "name")'; j "$L" | grep -q 'WD NAS App Builder (repo.test)' && j "$L" | grep -q 'WD NAS App Builder (evil.test)' && pass "same-named repositories told apart: $(j "$L")" || fail "labels: $(j "$L")"
F='array_values(array_filter($d["apps"], function($a){return $a["id"]==="python" && $a["repo"]===getenv("FORK");}))[0]'
export FORK; [ "$(j "$F[\"from_here\"]")" = false ] && [ "$(j "$F[\"update\"]")" = false ] && [ "$(j "$F[\"source_name\"]")" = '"WD NAS App Builder (repo.test)"' ] && pass "the fork's python: installed from the original, so no update from the fork" || fail "fork entry: $(j "$F")"
post start -d job=app_update -d repo=$FORK -d id=python >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && grep -q "99.1" $P/python/apkg.rc && grep -q "$FORK" $P/_store/installed_apps.json && get job >/dev/null && j '$d["job"]["title"]' | grep -q "Switching Python to WD NAS App Builder (evil.test)" && pass "switched to the fork: $(j '$d["job"]["title"]')" || fail "switch: $JOB_STATE $JOB_MSG $(cat $P/_store/installed_apps.json)"
post remove_repo -d url=$FORK >/dev/null
# (an app whose web interface only answers a few seconds after it starts, on the NAS itself: the job waits for it)
python3 /tbin/repotool.py set-app /www/repo python version '"99.2"'; python3 /tbin/repotool.py set-app /www/repo python web '{"local_port": 18999}'; post refresh >/dev/null
(sleep 4; python3 -m http.server 18999 --bind 127.0.0.1 > /dev/null 2>&1) &
post start -d job=app_update -d repo=$REPO -d id=python >/dev/null; job_wait
get job >/dev/null; W=$(j '$d["log"]' | grep -o "It's ready (answered after [0-9]* seconds)")
[ "$JOB_STATE" = '"done"' ] && [ -n "$W" ] && [ "$(echo "$W" | grep -o '[0-9][0-9]*')" -ge 3 ] && pass "waited for its web interface before saying it's installed: $W" || fail "web wait: $JOB_STATE $JOB_MSG $(j '$d["log"]' | tail -c 300)"
pkill -f "http.server 18999"
python3 /tbin/repotool.py set-app /www/repo nano version '"99.0"'; post refresh >/dev/null
post start -d job=app_update -d repo=$REPO -d id=nano >/dev/null; job_wait
[ "$JOB_STATE" = '"failed"' ] && grep -q -v "99.0" $P/nano/apkg.rc && pass "nano (no keeps_data) not updated by the Store: $JOB_MSG" || fail "nano update: $JOB_STATE $JOB_MSG"
echo "== installed apps (the Installed tab)"
get catalogue >/dev/null; N='array_values(array_filter($d["installed_apps"], function($a){return $a["id"]==="nano";}))[0]'
[ "$(j "$N[\"center_type\"]")" = 1 ] && [ "$(j "$N[\"url\"]")" = '"index.php"' ] && [ "$(j "$N[\"repo\"]")" = "\"$REPO\"" ] && j "$N[\"icon\"]" | grep -q '^"/apps/nano/' && pass "nano listed as WD lists it (center_type before name read right): $(j "$N" | cut -c1-200)" || fail "installed_apps: $(j '$d["installed_apps"]' | cut -c1-400)"
mkdir -p $P/needsnano; printf 'Package:\t\t\tneedsnano\nVersion:\t\t\t1.0\nAddonShowName:\t\tNeeds Nano\nInstDepend:\t\tnano\n' > $P/needsnano/apkg.rc; sh /tbin/apkg_xml.sh
[ "$(post start -d job=app_uninstall -d id=nano)" = 409 ] && pass "removing an app another needs refused: $(j '$d["error"]')" || fail "dependency: $(cat /tmp/body)"
rm -rf $P/needsnano; sh /tbin/apkg_xml.sh
post start -d job=app_uninstall -d id=nano >/dev/null; job_wait; [ "$JOB_STATE" = '"done"' ] && [ ! -d $P/nano ] && pass "uninstall: $JOB_MSG" || fail "uninstall: $JOB_MSG"
for app in badpkg downgrade nomodel; do post start -d job=app_install -d repo=$EVIL2 -d id=$app >/dev/null; job_wait; [ "$JOB_STATE" = '"failed"' ] && [ ! -d $P/$app ] && pass "$app refused: $(echo $JOB_MSG | cut -c1-110)" || fail "$app: $JOB_STATE $JOB_MSG"; done
[ -z "$(ls -A /usr/local/apps_upload)" ] && pass "no package left behind after failures" || fail "left: $(ls -A /usr/local/apps_upload)"
ls $V/Nas_Prog/_store/jobs/ | grep -q "^job-" && fail "job files left (they hold answers)" || pass "job files deleted once read"
echo "== permissions"; stat -c '%a %n' $P/_store $P/_store/repos.json $P/_store/jobs | tr '\n' ' '; echo
grep -i -E 'warning|fatal|notice|deprecated' /tmp/php.log | head -5
echo "== the Store removing itself (last: its page goes)"
post start -d job=app_uninstall -d id=store >/dev/null; for i in $(seq 1 30); do grep -q '"state": *"\(done\|failed\)"' $P/_store/jobs/status.json 2>/dev/null && break; sleep 1; done
grep -q '"state": *"done"' $P/_store/jobs/status.json && [ ! -d $P/store ] && [ ! -e /var/www/apps/store/api.php ] && [ -f $P/_store/repos.json ] && grep -q "del_apkg store" /tmp/wdtools.log && pass "removed itself with WD's uninstaller; its page gone, its settings kept ($(sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' $P/_store/jobs/status.json))" || fail "self-remove: $(cat $P/_store/jobs/status.json) $(ls $P)"
