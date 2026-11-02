# Recipes, with the small test recipe (fixtures/hello-1 and -2): requirements, the wizard and its checks, .env quoting,
# hooks, read-only mounts, the Nginx site, changing settings, updating, removing, reinstalling with the same secrets, an
# install undone after a failure, and a tampered recipe
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json; EVIL2=https://evil.test:8443/two/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null
post add_repo -d url=$REPO -d confirm=1 >/dev/null; post add_repo -d url=$EVIL2 -d confirm=1 >/dev/null
docker rm -f storehello-web-1 >/dev/null 2>&1
D=$P/_hello
echo '== requirements'
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; j '$d["problems"]' | grep -q 'Install the Docker app first' && pass "needs the Docker app: $(j '$d["problems"][0]["message"]')" || fail "requires: $(cat /tmp/body | cut -c1-300)"
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
echo '== wizard'
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null
[ "$(j '$d["problems"]')" = '[]' ] && pass 'requirements met' || fail "problems: $(j '$d["problems"]')"
echo "  fields: $(j 'implode(",", array_map(function($f){return $f["key"]."=".json_encode($f["value"]);}, $d["wizard"]))')"
j '$d["description"]' | grep -q '&lt;script&gt;' && j '$d["description"]' | grep -q '<strong>tiny</strong>' && j '$d["description"]' | grep -q 'href=\\"https://example.com\\"' && pass 'description: Markdown made safe (script escaped, bold, https link)' || fail "md: $(j '$d["description"]')"
mkdir -p $V/Public/photos1 "$V/Public/Paul's Photos"; echo x > $V/Public/photos1/a.jpg
BAD='{"SITE_FOLDER":"/etc","EXTRA":["'$P'"],"GREETING":"x","LOUD":false,"COLOUR":"green","TZ":"Mars/Base","ADMIN_PASSWORD":"short"}'
[ "$(post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode "answers=$BAD")" = 400 ] && pass "bad answers refused before starting: $(j 'implode(" | ", array_map(function($k,$v){return "$k: $v";}, array_keys($d["fields"]), $d["fields"]))' | cut -c1-400)" || fail "bad: $(cat /tmp/body)"
GOOD='{"SITE_FOLDER":"'$V'/Public/hello-site","EXTRA":["'$V'/Public/photos1","'$V'/Public/Paul'"'"'s Photos"],"GREETING":"Hi $HOME '"'"'q'"'"' #hash","LOUD":true,"COLOUR":"red","TZ":"Europe/Paris","ADMIN_PASSWORD":"secret-pass-1"}'
echo '== install'
docker rmi -f busybox:1.36 > /dev/null 2>&1
post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode "answers=$GOOD" >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && pass "installed: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG"; get job >/dev/null; j '$d["log"]' | tail -20; }
get job >/dev/null; L=$(j '$d["log"]' | tr '\\' '\n')
echo "$L" | grep -q 'Pulled' && ! echo "$L" | grep -q -E '[0-9a-f]{12} (Downloading|Extracting|Pull complete|Pulling fs layer)' \
    && pass "the download in the log: each image pulled, not each layer's progress ($(echo "$L" | grep -c "") lines)" || fail "pull log: $(echo "$L" | grep -E "Pull|Extract" | head -5)"
get job >/dev/null; j '$d["log"]' | grep -q "It's ready (answered after" && echo "$JOB_MSG" | grep -q 'is installed and ready' && pass "waited for its web interface: $(j '$d["log"]' | grep "It's ready")" || fail "ready: $JOB_MSG"
PAGE=$(curl -s http://127.0.0.1:18081/); echo "  page: $PAGE"
echo "$PAGE" | grep -qF "Hi \$HOME 'q' #hash red loud=yes v1 extra=Public," && pass ".env values reach the container exactly (\$, quotes, #; boolean as yes)" || fail 'page'
[ "$(stat -c %a $D/.env)" = 600 ] && [ "$(stat -c %a $D)" = 700 ] && pass '.env 600, folder 700' || fail "perms $(stat -c %a $D/.env $D)"
grep -q 'secret-pass-1' $D/.store/installed.json || grep -q 'TOKEN' $D/.store/installed.json && fail 'secrets in installed.json' || pass 'installed.json holds no password or secret'
TOKEN1=$(sed -n 's/^TOKEN=//p' $D/.env); [ ${#TOKEN1} = 24 ] && pass "secret generated (24 hex: $TOKEN1)" || fail "token: $TOKEN1"
echo '  .env:'; sed 's/^/    /' $D/.env
grep -c "pwd=$D token_length=24" $D/hooks.log | grep -q 2 && grep -q '^install version=1.0.0-1 previous= ' $D/hooks.log && pass "pre/post_install hooks ran in {data} with .env + STORE_* ($(head -1 $D/hooks.log | cut -c1-90))" || fail "hooks: $(cat $D/hooks.log)"
docker inspect storehello-web-1 --format '{{range .Mounts}}{{.Destination}}={{.RW}} {{end}}' > /tmp/mounts; grep -q '/extra/Public/photos1=false' /tmp/mounts && grep -q "/extra/Public/Paul's Photos=false" /tmp/mounts && pass "extra folders mounted read only: $(cat /tmp/mounts)" || fail "mounts: $(cat /tmp/mounts)"
# A folder for several services (the same path in each - e.g. Sonarr and Bazarr): checked and written for each
R=$(STORE_TEST_VOLUME=$V php -r 'require $argv[1]; $o = ["key" => "TV", "type" => "folder", "label" => "TV", "multiple" => true, "mount" => ["service" => ["sonarr", "bazarr"], "target" => "/media"]];
	$bad = ["key" => "TV", "type" => "folder", "label" => "TV", "mount" => ["service" => ["sonarr", "bad name"], "target" => "/media"]];
	$text = store_override_text(["options" => [$o]], ["TV" => [$argv[2] . "/Public/TV"]]);
	echo store_check_option($o) === "" && store_check_option($bad) !== "" && strpos($text, "  sonarr:\n    volumes:") !== false && strpos($text, "  bazarr:\n    volumes:") !== false
		&& substr_count($text, "target: \"/media/Public/TV\"") === 2 ? "ok" : "no: " . $text;' $P/store/lib/store.php $V)
[ "$R" = ok ] && pass 'a folder mounted into several services, at the same path (a bad service name refused)' || fail "several services: $R"
[ -f $P/_nginx/sites/60-app-hello.conf ] && grep -q 'proxy_buffering         off' $P/_nginx/sites/60-app-hello.conf && echo "$JOB_MSG" | grep -q 'https://hello.nas.example.test/' && pass 'Nginx site added (stream) and its address shown' || fail "nginx: $(ls $P/_nginx/sites)"
get job >/dev/null; j '$d["log"]' | grep -q "Extra folders: $V/Public/photos1 is /extra/Public/photos1 in Hello (test)" && pass 'mounted folders listed in the log' || fail "mount log: $(j '$d["log"]' | grep -i extra)"
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; [ "$(j '$d["mounts"][1][2]')" = "\"/extra/Public/Paul's Photos\"" ] && pass "details list the folders as the app sees them: $(j '$d["mounts"]')" || fail "mounts: $(j '$d["mounts"]')"
get catalogue >/dev/null; [ "$(j 'array_values(array_filter($d["recipes"], function($r){return $r["id"]==="hello";}))[0]["installed"]')" = '"1.0.0-1"' ] && pass 'catalogue shows it installed' || fail 'catalogue'
echo '== change settings'
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; echo "  settings: $(j 'implode(",", array_map(function($f){return $f["key"].(isset($f["saved"])?"(saved)":"");}, $d["settings"]))'); deletable: $(j '$d["deletable"]')"
CHG='{"SITE_FOLDER":"'$V'/Public/hello-site","EXTRA":[],"GREETING":"Changed","LOUD":false,"COLOUR":"blue","TZ":"Europe/London","ADMIN_PASSWORD":""}'
post start -d job=recipe_change -d id=hello --data-urlencode "answers=$CHG" >/dev/null; job_wait; sleep 2
curl -s http://127.0.0.1:18081/ | grep -q "^Changed blue loud=no v1 extra=$" && [ ! -f $D/compose.override.yaml ] && grep -q 'ADMIN_PASSWORD=secret-pass-1' $D/.env && [ "$(sed -n 's/^TOKEN=//p' $D/.env)" = "$TOKEN1" ] && pass "settings changed and applied (override removed; empty password kept; secret kept): $JOB_MSG" || fail "change: $JOB_STATE $JOB_MSG $(curl -s http://127.0.0.1:18081/)"
echo '== its repository removed, then added again'
post remove_repo -d url=$REPO >/dev/null; get catalogue >/dev/null
[ "$(j 'array_column($d["orphan_recipes"], "id")')" = '["hello"]' ] && [ "$(j 'array_column($d["orphan_recipes"], "repo")')" = "[\"$REPO\"]" ] && pass 'still listed as installed (from a repository no longer read)' || fail "orphans: $(j '$d["orphan_recipes"]')"
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; [ "$(j '$d["orphan"]')" = "\"$REPO\"" ] && [ "$(j 'count($d["settings"]) > 0')" = true ] && [ "$(j '$d["update_fields"]')" = '[]' ] && pass 'its page from the recipe kept in its folder: settings, no updates' || fail "orphan details: $(cut -c1-300 /tmp/body)"
post start -d job=recipe_change -d id=hello --data-urlencode "answers=$(echo "$CHG" | sed 's/"Changed"/"Orphaned"/')" >/dev/null; job_wait; sleep 2
curl -s http://127.0.0.1:18081/ | grep -q '^Orphaned ' && pass "its settings still change: $JOB_MSG" || fail "orphan change: $JOB_STATE $JOB_MSG"
CHG=$(echo "$CHG" | sed 's/"Changed"/"Orphaned"/')
post add_repo -d url=$REPO -d confirm=1 >/dev/null; get catalogue >/dev/null
[ "$(j 'count($d["orphan_recipes"])')" = 0 ] && [ "$(j 'array_values(array_filter($d["recipes"], function($r){return $r["id"]==="hello";}))[0]["installed"]')" = '"1.0.0-1"' ] && pass 'added again: matched up with its install' || fail "re-added: $(j '$d["orphan_recipes"]')"
echo '== update'
python3 /tbin/repotool.py add-recipe /www/repo /tfix/hello-2; post refresh >/dev/null
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; [ "$(j 'array_map(function($f){return $f["key"];}, $d["update_fields"])')" = '["NEW_SETTING"]' ] && pass 'update asks only the new option' || fail "update fields: $(j '$d["update_fields"]')"
post start -d job=recipe_update -d id=hello --data-urlencode 'answers={"NEW_SETTING":"brand new"}' >/dev/null; job_wait; sleep 2
curl -s http://127.0.0.1:18081/ | grep -q '^Orphaned blue loud=no v2 new=brand new' && grep -q '^update version=1.0.0-2 previous=1.0.0-1' $D/hooks.log && grep -q '"version": "1.0.0-2"' $D/.store/installed.json && pass "updated with pre/post_update hooks: $JOB_MSG" || fail "update: $JOB_STATE $JOB_MSG $(tail -2 $D/hooks.log)"
echo '== uninstall (keeping its folder)'
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; echo "  deletable: $(j '$d["deletable"]')"
post start -d job=recipe_uninstall -d id=hello --data-urlencode 'delete=["SITE_FOLDER"]' >/dev/null; job_wait
[ -z "$(docker ps -aq --filter name=storehello)" ] && [ ! -d $V/Public/hello-site ] && [ -f $D/.env ] && [ ! -f $D/.store/installed.json ] && [ ! -f $P/_nginx/sites/60-app-hello.conf ] && grep -q '^uninstall ' $D/hooks.log && [ -d $V/Public/photos1 ] && pass "removed: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG"
echo '== reinstall (settings reused)'
get details "&kind=recipes&repo=$REPO&id=hello" >/dev/null; [ "$(j '$d["existing"]')" = "\"$D\"" ] && j '$d["wizard"]' | grep -q '"value":"Orphaned"' && pass 'earlier settings found and filled in' || fail "existing: $(j '$d["existing"]')"
post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode 'answers={"SITE_FOLDER":"'$V'/Public/hello-site","EXTRA":[],"GREETING":"Again","LOUD":false,"COLOUR":"blue","TZ":"Europe/London","NEW_SETTING":"n","ADMIN_PASSWORD":""}' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ "$(sed -n 's/^TOKEN=//p' $D/.env)" = "$TOKEN1" ] && grep -q 'ADMIN_PASSWORD=secret-pass-1' $D/.env && pass 'reinstalled with the same secret and password' || fail "reinstall: $JOB_STATE $JOB_MSG"
post start -d job=recipe_uninstall -d id=hello -d delete_data=1 --data-urlencode 'delete=["SITE_FOLDER"]' >/dev/null; job_wait
[ ! -d $D ] && [ -z "$(docker ps -aq --filter name=storehello)" ] && pass "removed with its folder: $JOB_MSG" || fail "delete data: $JOB_MSG"
echo '== failures'
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0",18081)); s.listen(); time.sleep(120)' & BLOCK=$!; sleep 1
CHG2=$(echo "$CHG" | sed "s/}$/,\"NEW_SETTING\":\"n\"}/; s/\"ADMIN_PASSWORD\":\"\"/\"ADMIN_PASSWORD\":\"another-pass\"/"); [ "$(post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode "answers=$CHG2")" = 200 ] || echo "  start: $(cat /tmp/body)"; job_wait; kill $BLOCK
[ "$JOB_STATE" = '"failed"' ] && [ ! -d $D ] && [ -z "$(docker ps -aq --filter name=storehello)" ] && pass "failed start undone (folder and containers removed): $JOB_MSG" || fail "rollback: $JOB_STATE $JOB_MSG $(ls $D 2>&1)"
[ "$(get details "&kind=recipes&repo=$EVIL2&id=tampered")" = 502 ] && pass "tampered recipe refused: $(j '$d["error"]')" || fail "tampered: $(cat /tmp/body | cut -c1-200)"
get job >/dev/null; j '$d["log"]' | grep -i 'PHP warning' | head -3
grep -i -E 'warning|fatal|notice|deprecated' /tmp/php.log | head -5
