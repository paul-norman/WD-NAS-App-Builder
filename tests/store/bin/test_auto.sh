# Automatic updates: ticking apps and recipes, the nightly run (lib/auto_update.php) - nothing started when nothing is
# newer, apps updated from their repository, updates left for the user (no keeps_data, manual_update) and said why,
# an ntfy notification (a stand-in ntfy on 127.0.0.1:2586), a recipe updated, the cron lines, and the Store itself
# updated last
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null
post add_repo -d url=$REPO -d confirm=1 >/dev/null
docker rm -f storehello-web-1 >/dev/null 2>&1
auto() { STORE_TEST_VOLUME=$V php $P/store/lib/auto_update.php; }
last() { php -r '$d=json_decode(file_get_contents($argv[1]),true); foreach ($d["results"] as $r) echo $r["id"].":".$r["state"].":".($r["to"] ?? "").":".($r["reason"] ?: $r["message"])."\n";' $P/_store/auto_update_last.json; }

echo '== the cron lines'
mkdir -p /var/spool/cron/crontabs; echo '0 1 * * * true # other' > /var/spool/cron/crontabs/root
sh $P/store/init.sh $P/store >/dev/null 2>&1; sh $P/store/init.sh $P/store >/dev/null 2>&1
C1=$(cat /var/spool/cron/crontabs/root)
echo "$C1" | grep -q "^25 4 \* \* \* php $P/store/lib/refresh.php .*# store-refresh$" && echo "$C1" | grep -q "^30 4 \* \* \* php $P/store/lib/auto_update.php .*# store-auto-update$" \
    && [ "$(echo "$C1" | wc -l)" = 3 ] && pass 'the check at 04:25 and the updates at 04:30 added once (init.sh run twice)' || fail "cron: $C1"
sh $P/store/clean.sh $P/store >/dev/null 2>&1; [ "$(cat /var/spool/cron/crontabs/root)" = '0 1 * * * true # other' ] && pass 'both removed by clean.sh, the rest left' || fail "cron after clean: $(cat /var/spool/cron/crontabs/root)"
sh $P/store/init.sh $P/store >/dev/null 2>&1

echo '== ticking'
post start -d job=app_install -d repo=$REPO -d id=keeper >/dev/null; job_wait
post start -d job=app_install -d repo=$REPO -d id=plain >/dev/null; job_wait
[ "$(post auto_set -d kind=apps -d id=keeper -d on=1)" = 200 ] && [ "$(j '$d["auto"]["apps"]')" = '["keeper"]' ] && pass 'keeper ticked' || fail "tick: $(cat /tmp/body)"
[ "$(post auto_set -d kind=apps -d id=nothere -d on=1)" = 404 ] && pass "an app that isn't installed can't be ticked: $(j '$d["error"]')" || fail "not installed: $(cat /tmp/body)"
post auto_set -d kind=apps -d id=plain -d on=1 >/dev/null; post auto_set -d kind=apps -d id=plain -d on=0 >/dev/null; post auto_set -d kind=apps -d id=plain -d on=1 >/dev/null
[ "$(j '$d["auto"]["apps"]')" = '["keeper","plain"]' ] && pass 'ticked, unticked and ticked again: listed once' || fail "list: $(j '$d["auto"]["apps"]')"
[ "$(post auto_topic -d topic='bad topic!')" = 400 ] && pass "a bad ntfy topic refused: $(j '$d["error"]')" || fail 'bad topic accepted'

echo '== nothing newer'
get job >/dev/null; BEFORE=$(j '$d["job"]["id"]')
auto; get job >/dev/null
[ "$(j '$d["job"]["id"]')" = "$BEFORE" ] && [ "$(last | tr '\n' ' ')" = 'keeper:current:1.0: plain:current:1.0: ' ] && pass 'no job started; recorded as up to date' || fail "nothing newer: $(j '$d["job"]["id"]') $(last)"

echo '== newer versions'
python3 /tbin/repotool.py set-app /www/repo keeper version '"2.0"'; python3 /tbin/repotool.py set-app /www/repo plain version '"2.0"'; post refresh >/dev/null
get catalogue >/dev/null
[ "$(j '$d["auto"]["plan"]["apps:keeper"]["state"]')" = '"update"' ] && j '$d["auto"]["plan"]["apps:plain"]["reason"]' | grep -q "without losing its settings" \
    && pass "the page shows tonight's plan: keeper updated, plain left ($(j '$d["auto"]["plan"]["apps:plain"]["reason"]'))" || fail "plan: $(j '$d["auto"]["plan"]')"
auto; get job >/dev/null
[ "$(j '$d["job"]["state"]')" = '"done"' ] && grep -q '2.0' $P/keeper/apkg.rc && grep -q '1.0' $P/plain/apkg.rc && [ "$(j '$d["job"]["message"]')" = '"Automatic updates: 1 updated, 1 skipped"' ] \
    && pass "updated as a job (shown on Activity): $(j '$d["job"]["message"]')" || fail "run: $(j '$d["job"]') $(j '$d["log"]' | tail -c 400)"
last | grep -q '^keeper:updated:2.0:Keeper 2.0 is installed' && last | grep -q "^plain:skip:2.0:.*update it by hand" && pass 'each one recorded' || fail "last: $(last)"
grep -q "\"repo\": \"$REPO\"" $P/_store/installed_apps.json && pass "keeper's repository recorded as its source" || fail "source: $(cat $P/_store/installed_apps.json)"

echo '== an update that needs the user (manual_update)'
python3 /tbin/repotool.py set-app /www/repo keeper version '"3.0"'; python3 /tbin/repotool.py set-app /www/repo keeper manual_update '{"version": "3.0", "reason": "its data needs upgrading first"}'; post refresh >/dev/null
auto; grep -q '2.0' $P/keeper/apkg.rc && last | grep -q '^keeper:skip:3.0:updating to 3.0 or later needs doing by hand: its data needs upgrading first' \
    && pass "left for the user: $(last | grep '^keeper' | cut -d: -f4-)" || fail "manual: $(last) $(cat $P/keeper/apkg.rc | grep Version)"
get details "&kind=apps&repo=$REPO&id=keeper" >/dev/null; [ "$(j '$d["version"]')" = '"3.0"' ] && pass 'updating it from its page still offered' || fail "details: $(j '$d["version"]')"

echo '== telling ntfy'
mkdir -p $P/ntfy $P/_ntfy; printf 'Package:\t\t\tntfy\nVersion:\t\t\t2.0\nAddonShowName:\t\tntfy\n' > $P/ntfy/apkg.rc; sh /tbin/apkg_xml.sh; echo 'tk_testtoken' > $P/_ntfy/token
python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"] or 0)).decode()
        open("/tmp/ntfy.log", "a").write(self.path + "|" + self.headers["Authorization"] + "|" + self.headers["Title"] + "|" + body.replace("\n", " / ") + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *args): pass
http.server.HTTPServer(("127.0.0.1", 2586), H).serve_forever()' & NTFY=$!; sleep 1
get catalogue >/dev/null; [ "$(j '$d["auto"]["ntfy"]')" = true ] && pass "the page offers ntfy (it's installed)" || fail 'no ntfy'
[ "$(post auto_topic -d topic=nas)" = 200 ] && [ "$(j '$d["auto"]["topic"]')" = '"nas"' ] && pass 'topic saved' || fail "topic: $(cat /tmp/body)"
python3 /tbin/repotool.py set-app /www/repo keeper version '"2.1"'; python3 /tbin/repotool.py set-app /www/repo keeper manual_update 'null'; post refresh >/dev/null
rm -f /tmp/ntfy.log; auto; sleep 1
grep -q '^/nas|Bearer tk_testtoken|Store: automatic updates|Keeper updated to 2.1$' /tmp/ntfy.log && pass "ntfy told: $(cat /tmp/ntfy.log)" || fail "ntfy: $(cat /tmp/ntfy.log 2>&1)"
python3 /tbin/repotool.py set-app /www/repo plain version '"2.0"'; post refresh >/dev/null
rm -f /tmp/ntfy.log; auto; sleep 1
[ ! -f /tmp/ntfy.log ] && pass 'not told again about an update already left for the user (plain 2.0)' || fail "told again: $(cat /tmp/ntfy.log)"
python3 /tbin/repotool.py set-app /www/repo plain version '"2.1"'; post refresh >/dev/null
rm -f /tmp/ntfy.log; auto; sleep 1
grep -q "Plain 2.1 not installed: it can't be updated" /tmp/ntfy.log && pass 'told about a newer version left for the user' || fail "new skip: $(cat /tmp/ntfy.log 2>&1)"
kill $NTFY

echo '== a recipe'
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode 'answers={"SITE_FOLDER":"'$V'/Public/hello-site","EXTRA":[],"GREETING":"Auto","LOUD":false,"COLOUR":"blue","TZ":"Europe/London","ADMIN_PASSWORD":"secret-pass-1"}' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && post auto_set -d kind=recipes -d id=hello -d on=1 >/dev/null && [ "$(j '$d["auto"]["recipes"]')" = '["hello"]' ] && pass 'hello installed and ticked' || fail "hello: $JOB_STATE $JOB_MSG"
python3 /tbin/repotool.py add-recipe /www/repo /tfix/hello-2; post refresh >/dev/null
auto; sleep 2
curl -s http://127.0.0.1:18081/ | grep -q '^Auto blue loud=no v2 new=fresh' && last | grep -q '^hello:updated:1.0.0-2:' && pass "recipe updated, its new option at its default: $(curl -s http://127.0.0.1:18081/)" || fail "recipe: $(last) $(curl -s http://127.0.0.1:18081/)"
# A new version with a new password: it can't be made up, so the update is left for the user (nothing changed)
rm -rf /tmp/hello-3; cp -r /tfix/hello-2 /tmp/hello-3
python3 -c 'import json, sys; f = sys.argv[1]; r = json.load(open(f)); r["version"] = "1.0.0-3"; r["options"].append({"key": "NEW_PASSWORD", "type": "password", "label": "New password", "min_length": 8}); json.dump(r, open(f, "w"), indent=4)' /tmp/hello-3/recipe.json
python3 /tbin/repotool.py add-recipe /www/repo /tmp/hello-3; post refresh >/dev/null
auto; sleep 1
last | grep -q '^hello:skip:1.0.0-3:its new version needs settings - update it from its page' && curl -s http://127.0.0.1:18081/ | grep -q '^Auto blue loud=no v2' && grep -q '"version": "1.0.0-2"' $P/_hello/.store/installed.json \
    && pass "a new password left for the user, 1.0.0-2 untouched: $(last | grep '^hello' | cut -d: -f4- | cut -c1-110)" || fail "new password: $(last | grep '^hello')"
post start -d job=recipe_uninstall -d id=hello -d delete_data=1 --data-urlencode 'delete=["SITE_FOLDER"]' >/dev/null; job_wait
get catalogue >/dev/null; [ "$(j '$d["auto"]["plan"]["recipes:hello"]["reason"]')" = "\"it isn't installed\"" ] && pass 'removed: shown as not installed' || fail "removed: $(j '$d["auto"]["plan"]')"
post auto_set -d kind=recipes -d id=hello -d on=0 >/dev/null

echo '== the Store itself, last'
# Ticked first, so it would be first if the Store didn't put itself last
for change in 'keeper 0' 'plain 0' 'store 1' 'keeper 1'; do
    set -- $change; post auto_set -d kind=apps -d id=$1 -d on=$2 >/dev/null
done

STORE_FROM=$(sed -n 's/^Version:[ \t]*//p' $P/store/apkg.rc)
python3 /tbin/repotool.py set-app /www/repo store version '"99.0"'; python3 /tbin/repotool.py set-app /www/repo keeper version '"2.2"'; post refresh >/dev/null
get catalogue >/dev/null; [ "$(j 'array_column(array_values($d["auto"]["plan"]), "id")')" = '["keeper","store"]' ] && pass "planned: keeper, then the Store (though ticked first)" || fail "order: $(j 'array_column(array_values($d["auto"]["plan"]), "id")')"
auto
grep -q '99.0' $P/store/apkg.rc && grep -q '2.2' $P/keeper/apkg.rc && grep -n '== Updating' $P/_store/jobs/job.log | tr '\n' ' ' | grep -q "Keeper.*Store" \
    && pass "keeper, then the Store updated itself ($STORE_FROM -> 99.0): $(grep -o '"message": *"[^"]*"' $P/_store/jobs/status.json)" || fail "store: $(cat $P/_store/jobs/status.json) $(grep '==' $P/_store/jobs/job.log)"
grep -i -E 'warning|fatal|notice|deprecated' /tmp/php.log $P/_store/jobs/job.log | head -5
