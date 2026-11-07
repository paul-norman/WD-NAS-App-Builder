#!/bin/sh
# Scrutiny from its package (tests/common/nas.sh), with the Nginx and ntfy apps: InfluxDB and Scrutiny as its own user,
# on the NAS itself only, InfluxDB set up by Scrutiny, a disk's SMART data read by its collector (a stand-in smartctl:
# the container has no disks - Scrutiny's own example of a WD Red's data) and shown on the page, its site through Nginx
# (asking for the app's login first), alerts to the ntfy app's topic (a test alert arriving there), a restart keeping its
# history, removal
. /t/common/nas.sh scrutiny
DOMAIN=nas.example.test
S=http://127.0.0.1:8091
site() { p=$1; shift; curl -sk -m 10 --resolve "scrutiny.$DOMAIN:443:127.0.0.1" "$@" "https://scrutiny.$DOMAIN$p"; }
# Waits for the disk reader to finish (up to 2 minutes)
collected() { i=0; while [ $i -lt 60 ] && { [ -d /var/run/scrutiny-collect ] || [ ! -s $D/last_collect ]; }; do sleep 2; i=$((i + 1)); done; [ ! -d /var/run/scrutiny-collect ]; }
mkdir -p /tmp/fake && cp /t/app/smartctl/* /tmp/fake/ && chmod 755 /tmp/fake/smartctl

echo '== with Nginx and ntfy'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN
install_app ntfy
wait_port 2586 30 && pass 'ntfy answering' || fail "ntfy: $(tail -n 5 /tmp/start.log)"

echo '== installed and started'
install_app
wait_port 8091 180 && pass 'answering on 8091' || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/influxd.log; tail -n 10 $D/scrutiny.log)"; exit 1; }
PID=$(cat /var/run/scrutiny.pid); IPID=$(cat /var/run/scrutiny-influxd.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 65 ] && [ "$(awk '/^Uid:/ { print $2 }' /proc/$IPID/status)" = 65 ] \
    && [ "$(stat -c '%U %a' $D/db)" = 'scrutiny 700' ] && [ "$(stat -c '%U %a' $D/influxdb)" = 'scrutiny 700' ] \
    && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%U %G %a' $D/scrutiny.yaml)" = 'root scrutiny 640' ] \
    && pass "Scrutiny and InfluxDB run as its own user (65), their data their own, its settings root's" \
    || fail "users: $(grep '^Uid:' /proc/$PID/status /proc/$IPID/status | tr '\n' ' ') $(ls -la $D)"
L=$(awk 'FNR > 1 && $4 == "0A" { split($2, l, ":"); if (l[2] == "1F9B" || l[2] == "1F9D") print l[1] }' /proc/net/tcp /proc/net/tcp6 | sort -u | tr '\n' ' ')
[ "$L" = '0100007F ' ] && pass 'Scrutiny (8091) and InfluxDB (8093) only on the NAS itself (127.0.0.1)' || fail "listening: $L"
curl -sf $S/api/health | grep -q '"success":true' && curl -sf http://127.0.0.1:8093/api/v2/setup | grep -q '"allowed": false' \
    && pass 'Scrutiny healthy, InfluxDB set up by it' || fail "health: $(curl -s $S/api/health) $(tail -n 5 $D/scrutiny.log)"
grep -q 'scrutiny-collect' /var/spool/cron/crontabs/root && pass 'its disks read hourly from cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"

echo '== a disk'
collected
rm -f /tmp/smartctl-calls
SMARTCTL=/tmp/fake/smartctl sh $P/scrutiny/scrutiny_ctl.sh collect > /tmp/collect.log 2>&1
SUM=$(curl -s $S/api/summary)
echo "$SUM" | grep -q 'WDC WD140EDFZ-11A0VA0' && [ "$(sed -n 2p $D/last_collect)" = 0 ] && grep -q -- '--xall --json -T permissive -n standby' /tmp/smartctl-calls \
    && pass "a disk's SMART data read by its collector (sleeping disks left asleep: -n standby) and in Scrutiny" \
    || fail "collect: $(cat /tmp/collect.log; tail -n 8 $D/collector.log; cat /tmp/smartctl-calls; echo "$SUM" | head -c 300)"
grep -q "metrics_smartctl_bin: '/tmp/fake/smartctl'" $D/collector.yaml && grep -A1 -- '- device: /dev/sda$' $D/collector.yaml | grep -q "type: 'sat'" \
    && grep -c -- '- device: /dev/sd' $D/collector.yaml | grep -qx "$(ls -d /sys/block/sd* | wc -l)" && [ "$(stat -c '%u %a' $D/collector.yaml)" = '0 600' ] \
    && pass "the collector's settings written for each run (each disk read as SATA, those asleep left out)" || fail "collector.yaml: $(cat $D/collector.yaml)"
SMARTCTL=/tmp/fake/smartctl sh $P/scrutiny/scrutiny_ctl.sh collect > /dev/null 2>&1
mv /tmp/fake/smartctl /tmp/fake/smartctl.real && printf '#!/bin/sh\ncase "$*" in *"-n standby -i"*) exit 2 ;; esac\nexec /tmp/fake/smartctl.real "$@"\n' > /tmp/fake/smartctl && chmod 755 /tmp/fake/smartctl
rm -f /tmp/smartctl-calls; SMARTCTL=/tmp/fake/smartctl sh $P/scrutiny/scrutiny_ctl.sh collect > /dev/null 2>&1
grep -A1 -- '- device: /dev/sda$' $D/collector.yaml | grep -q 'ignore: true' && ! grep -q -- '--xall' /tmp/smartctl-calls \
    && pass 'a disk asleep is left out (not read at all)' || fail "asleep: $(cat $D/collector.yaml; cat /tmp/smartctl-calls)"
mv -f /tmp/fake/smartctl.real /tmp/fake/smartctl

echo '== its page'
page_up scrutiny
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"0.10.0"' ] \
    && [ "$(echo "$ST" | j '$d["disks"][0]["model"]')" = '"WDC WD140EDFZ-11A0VA0"' ] && [ "$(echo "$ST" | j '$d["disks"][0]["status"]')" = '"passed"' ] \
    && [ "$(echo "$ST" | j '$d["disks"][0]["temperature"] > 0')" = true ] && [ "$(echo "$ST" | j '$d["collect_ok"]')" = true ] \
    && pass "status: running, 0.10.0, the disk ($(echo "$ST" | j '$d["disks"][0]["name"]'), healthy, $(echo "$ST" | j '$d["disks"][0]["temperature"]') °C)" \
    || fail "status: $(echo "$ST" | head -c 600)"
[ "$(post password -d show=1 | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the password shown' || fail 'password'
R=$(post collect -d confirm=1); sleep 1
[ "$(echo "$R" | j '$d["ok"]')" = true ] && collected && pass 'its disks read from the page (in the background)' || fail "collect: $R"

echo '== its site through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8091' $P/_nginx/sites/60-app-scrutiny.conf 2>/dev/null && [ "$(site /web/ -o /dev/null -w '%{http_code}')" = 401 ] \
    && [ "$(site /api/summary -u admin:wrong -o /dev/null -w '%{http_code}')" = 401 ] && site /web/ -u "admin:$(cat $D/password)" | grep -qi '<app-root' \
    && site /api/summary -u "admin:$(cat $D/password)" | grep -q 'WD140EDFZ' \
    && pass "its site https://scrutiny.$DOMAIN/: nothing without the app's login (Nginx asks for it), its pages and API with it" \
    || fail "site: $(ls $P/_nginx/sites; site /web/ -u "admin:$(cat $D/password)" | head -c 200)"
[ "$(site / -o /dev/null -w '%{redirect_url}' -u "admin:$(cat $D/password)")" = "https://scrutiny.$DOMAIN/web/" ] && [ "$(get status | j '$d["site"]["url"]')" = "\"https://scrutiny.$DOMAIN/\"" ] \
    && pass 'its site goes to its start page (/web/), and the page links to it' || fail "start: $(site / -o /dev/null -w '%{redirect_url}') $(get status | j '$d["site"]')"
OLD=$(cat $D/password); NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"')
[ ${#NEW} = 20 ] && [ "$(site /web/ -u "admin:$OLD" -o /dev/null -w '%{http_code}')" = 401 ] && site /web/ -u "admin:$NEW" | grep -qi '<app-root' \
    && pass 'a new password: in use at once, the old one refused' || fail "new password: ${#NEW}"

echo '== alerts to ntfy'
R1=$(post settings -d 'ntfy_topic=no spaces')
R2=$(post settings -d ntfy_topic=disks); wait_port 8091 180; sleep 2
[ "$(echo "$R1" | j '$d["ok"]')" = false ] && [ "$(echo "$R2" | j '$d["ok"]')" = true ] && grep -q 'ntfy://:tk_[a-z0-9]*@127.0.0.1:2586/disks?scheme=http' $D/scrutiny.yaml \
    && pass "an ntfy topic set (not one with spaces): its alerts go to the ntfy app, with ntfy's token for the apps" || fail "topic: $R1 $R2 $(grep -A2 urls $D/scrutiny.yaml)"
R=$(post test_alert -d confirm=1); sleep 2
M=$(curl -s -m 5 -H "Authorization: Bearer $(cat $P/_ntfy/token)" 'http://127.0.0.1:2586/disks/json?poll=1')
[ "$(echo "$R" | j '$d["ok"]')" = true ] && echo "$M" | grep -qi 'test notification' \
    && pass 'a test alert from the page arrives in the ntfy app' || fail "alert: $R / $(echo "$M" | head -c 300) $(tail -n 3 $D/scrutiny.log)"
post settings -d ntfy_topic= > /dev/null; wait_port 8091 180
grep -q '^  urls: \[\]$' $D/scrutiny.yaml && curl -sf $S/api/summary | grep -q 'WD140EDFZ' \
    && pass 'no topic: no alerts - and its history kept across the restarts' || fail "no topic: $(grep -A2 urls $D/scrutiny.yaml)"

echo '== removal'
finish_app
[ ! -f /var/run/scrutiny.pid ] && [ ! -f /var/run/scrutiny-influxd.pid ] && ! grep -q 'scrutiny-' /var/spool/cron/crontabs/root \
    && [ ! -f $P/_nginx/sites/60-app-scrutiny.conf ] && [ -d $D/influxdb/engine ] && pass 'stopped (both), its cron lines and site gone, its history kept' \
    || fail "removal: $(ls /var/run; grep scrutiny /var/spool/cron/crontabs/root)"
finish_app ntfy
finish_app nginx
