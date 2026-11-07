#!/bin/sh
# rclone from its package (tests/common/nas.sh), with the Nginx app: its web interface (rcd: the interface's files and
# the API it calls on one port) as its own user in the share group, nothing without its login, a remote set up through
# its API (a local one standing in for cloud storage), the page's jobs (checked, copy and sync - a sync deleting what's
# gone from its source - run from the page and on the hour, their logs), the rclone command for SSH with the app's
# config, a new password, its site through Nginx, the network setting, removal
. /t/common/nas.sh rclone
DOMAIN=nas.example.test
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
R=http://127.0.0.1:5572
# Its API with a password (default: the app's): rc <command> [json]
rc() { curl -s -m 10 -u "admin:${3:-$(cat $D/password)}" -H 'Content-Type: application/json' -d "${2:-{\}}" "$R/$1"; }
site() { p=$1; shift; curl -sk -m 10 --resolve "rclone.$DOMAIN:443:127.0.0.1" "$@" "https://rclone.$DOMAIN$p"; }
bound() {
    awk -v port="$(printf '%04X' "$1")" 'FNR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print l[1] }' /proc/net/tcp /proc/net/tcp6 \
        | sed 's/^0*$/all/; s/^0100007F$/local/' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# Waits for a job's last run to finish (up to a minute): finished <id>
finished() { i=0; while [ $i -lt 30 ]; do case "$(cat $D/status/$1.json 2>/dev/null)" in *'"ok"'*|*'"failed"'*) return 0 ;; esac; sleep 2; i=$((i + 1)); done; return 1; }
state() { php -r '$s = json_decode((string)@file_get_contents($argv[1]), true); echo $s["state"] ?? "none";' $D/status/$1.json; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== installed and started'
install_app
wait_port 5572 30 && pass 'answering on 5572' || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/rclone.log)"; exit 1; }
PID=$(cat /var/run/rclone.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 68 ] && [ "$(awk '/^Gid:/ { print $2 }' /proc/$PID/status)" = 1000 ] \
    && [ "$(stat -c '%U %a' $D/config)" = 'rclone 700' ] && [ "$(stat -c '%U %a' $D/config/rclone.conf)" = 'rclone 600' ] \
    && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%U %a' $D/htpasswd)" = 'rclone 600' ] && grep -q '^admin:\$2' $D/htpasswd \
    && pass "runs as its own user (68) in the share group, its config its own, the password root's (bcrypt for rclone)" \
    || fail "user: $(grep -E '^(Uid|Gid):' /proc/$PID/status | tr '\n' ' ') $(ls -la $D)"
! grep -q 'ERROR' $D/rclone.log && pass 'nothing wrong in its log (no browser to open: its stand-in does nothing)' || fail "log: $(grep ERROR $D/rclone.log | head -n 2)"

echo '== nothing without its login'
C1=$(curl -s -m 5 -o /dev/null -w '%{http_code}' $R/); C2=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -d '{}' -H 'Content-Type: application/json' $R/config/listremotes)
C3=$(rc core/version '{}' wrong-password | head -c 100)
[ "$C1" = 401 ] && [ "$C2" = 401 ] && echo "$C3" | grep -qi 'unauthori\|401' && pass "its interface and API refuse requests without the login ($C1, $C2), and a wrong password" || fail "no login: $C1 $C2 $C3"
V_=$(rc core/version | php -r 'echo json_decode(stream_get_contents(STDIN), true)["version"] ?? "";')
[ "$V_" = v1.76.0 ] && pass "its API with the login: rclone $V_" || fail "version: $V_"
curl -s -m 5 -u "admin:$(cat $D/password)" $R/ | grep -q '<script type="module"' && curl -s -m 5 -u "admin:$(cat $D/password)" -L "$R/login?url=x" | grep -q '<div id="root">' \
    && pass "its web interface, from the same address - its pages too (/login, as a browser goes there)" || fail "interface: $(curl -s -m 5 -u "admin:$(cat $D/password)" $R/ | head -c 200)"

echo '== a remote, and the page'
mkdir -p $V/Public/Photos/2026 $V/Public/Cloud && echo one > $V/Public/Photos/a.jpg && echo two > $V/Public/Photos/2026/b.jpg && chmod -R 777 $V/Public/Photos $V/Public/Cloud
R1=$(rc config/create '{"name": "cloud", "type": "local", "parameters": {}}')
grep -q '^\[cloud\]' $D/config/rclone.conf && [ "$(stat -c '%U %a' $D/config/rclone.conf)" = 'rclone 600' ] \
    && pass "a remote set up through its API, as its web interface does (in its config, still its own)" || fail "remote: $R1 $(ls -l $D/config)"
page_up rclone
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"1.76.0"' ] && [ "$(echo "$ST" | j '$d["remotes"]')" = '{"cloud":"local"}' ] \
    && echo "$ST" | j '$d["address"]' | grep -q ':5572/"$' && pass "status: running, 1.76.0, its remotes (cloud, local), $(echo "$ST" | j '$d["address"]')" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password -d show=1 | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the password shown' || fail 'password'

echo '== jobs'
R1=$(post add_job -d name=Bad -d mode=copy -d source=$P/_rclone -d destination=cloud:$V/Public/Cloud -d hour=-1)
R2=$(post add_job -d name=Bad -d mode=copy -d source=$V/Public/Photos -d destination=nowhere:x -d hour=-1)
R3=$(post add_job -d name=Bad -d mode=move -d source=$V/Public/Photos -d destination=cloud:$V/Public/Cloud -d hour=-1)
R4=$(post add_job -d name=Bad -d mode=copy -d source=$V/Public/Photos -d destination=cloud:$V/Public/Cloud -d hour=24)
[ "$(echo "$R1$R2$R3$R4" | grep -o '"ok":false' | wc -l)" = 4 ] \
    && pass "refused: a folder in Nas_Prog ($(echo "$R1" | j '$d["error"]')), a remote not set up, another mode, hour 24" || fail "refusals: $R1 $R2 $R3 $R4"
R1=$(post add_job --data-urlencode 'name=Photos to the cloud' -d mode=copy -d source=$V/Public/Photos -d destination=cloud:$V/Public/Cloud -d hour=-1)
ID=$(get status | j '$d["jobs"][0]["id"]' | tr -d '"')
[ "$(echo "$R1" | j '$d["ok"]')" = true ] && [ -n "$ID" ] && [ "$(stat -c '%u %a' $D/jobs.json)" = '0 600' ] && pass "a copy job added (its list root's only)" || fail "add: $R1"
post run_job -d id=$ID > /dev/null
finished $ID && [ "$(state $ID)" = ok ] && [ "$(cat $V/Public/Cloud/2026/b.jpg 2>/dev/null)" = two ] \
    && [ "$(stat -c '%G' $V/Public/Cloud/2026)" = share ] && [ "$(( 0$(stat -c '%a' $V/Public/Cloud/2026/b.jpg) & 020 ))" != 0 ] \
    && pass "run from the page: copied, its files the share group's, writable by it ($(stat -c '%a %G' $V/Public/Cloud/2026/b.jpg))" \
    || fail "run: $(state $ID) $(ls -laR $V/Public/Cloud | head -n 12) $(tail -n 3 $D/status/$ID.log)"
L=$(post job_log -d id=$ID)
echo "$L" | j 'implode("\n", $d["log"])' | grep -q 'b.jpg' && [ "$(get status | j '$d["jobs"][0]["status"]["state"]')" = '"ok"' ] \
    && pass "its last run's log and state on the page" || fail "log: $(echo "$L" | head -c 300)"
echo three > $V/Public/Cloud/extra.jpg
post run_job -d id=$ID > /dev/null; finished $ID
[ -f $V/Public/Cloud/extra.jpg ] && pass 'a copy deletes nothing at its destination' || fail 'copy deleted'
HOUR=$(date +%H | sed 's/^0//')
post add_job -d name=Mirror -d mode=sync -d source=$V/Public/Photos -d destination=cloud:$V/Public/Cloud -d hour=$HOUR > /dev/null
ID2=$(get status | j '$d["jobs"][1]["id"]' | tr -d '"')
rm $V/Public/Photos/a.jpg
sh $P/rclone/rclone_ctl.sh due
[ "$(state $ID2)" = ok ] && [ ! -f $V/Public/Cloud/extra.jpg ] && [ ! -f $V/Public/Cloud/a.jpg ] && [ -f $V/Public/Cloud/2026/b.jpg ] && [ "$(state $ID)" = ok ] \
    && pass "a sync job run on the hour ($HOUR, from cron's due) - what's gone from its source deleted; the job set for no hour left alone" || fail "due: $(state $ID2) $(ls -R $V/Public/Cloud)"
grep -q "rclone_ctl.sh due # rclone-jobs" /var/spool/cron/crontabs/root && pass 'its jobs checked hourly from cron' || fail "cron: $(cat /var/spool/cron/crontabs/root)"
post delete_job -d id=$ID2 > /dev/null
[ "$(get status | j 'count($d["jobs"])')" = 1 ] && [ ! -f $D/status/$ID2.json ] && pass 'a job removed (its state and log too)' || fail "delete: $(get status | j '$d["jobs"]')"

echo '== the rclone command'
[ "$(readlink /usr/bin/rclone)" = $P/rclone/rclone_cli.sh ] && [ "$(rclone listremotes)" = 'cloud:' ] && [ "$(rclone cat cloud:$V/Public/Cloud/2026/b.jpg)" = two ] \
    && [ "$(stat -c '%U' $D/config/rclone.conf)" = rclone ] && pass "rclone for SSH: the app's remotes, as rclone's user (its config still its own)" \
    || fail "command: $(ls -l /usr/bin/rclone) $(rclone listremotes 2>&1 | head -n 3)"

echo '== a new password'
OLD=$(cat $D/password); NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"'); wait_port 5572 30
[ ${#NEW} = 20 ] && [ "$NEW" != "$OLD" ] && [ "$(rc core/version '{}' "$OLD" | grep -c version)" = 0 ] && rc core/version '{}' "$NEW" | grep -q v1.76.0 \
    && [ "$(get status | j '$d["answering"]')" = true ] && pass 'it works (the page too), the old one no longer does' || fail "new password: ${#NEW}"

echo '== its site through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:5572' $P/_nginx/sites/60-app-rclone.conf 2>/dev/null && site / -u "admin:$NEW" | grep -q '<div id="root">' \
    && site /core/version -u "admin:$NEW" -H 'Content-Type: application/json' -d '{}' | grep -q v1.76.0 \
    && pass "its site https://rclone.$DOMAIN/: the interface and its API" || fail "site: $(ls $P/_nginx/sites; site / -u "admin:$NEW" | head -c 200)"
[ "$(get status | j '$d["site"]["url"]')" = "\"https://rclone.$DOMAIN/\"" ] && pass 'the page shows its site' || fail "site: $(get status | j '$d["site"]')"

echo '== the network setting'
[ "$(bound 5572)" = all ] && pass 'on the network by default' || fail "bound: $(bound 5572)"
post settings -d listen=local > /dev/null; wait_port 5572 30
[ "$(bound 5572)" = local ] && site / -f --retry 5 --retry-all-errors --retry-delay 1 -u "admin:$NEW" | grep -q '<div id="root">' \
    && pass 'only through Nginx: on 127.0.0.1 only, its site still working' || fail "local: $(bound 5572)"

echo '== removal'
finish_app
[ ! -e /usr/bin/rclone ] && ! grep -q 'rclone-' /var/spool/cron/crontabs/root && [ ! -f /var/run/rclone.pid ] && [ ! -f $P/_nginx/sites/60-app-rclone.conf ] \
    && grep -q '^\[cloud\]' $D/config/rclone.conf && pass 'stopped, its command, cron lines and site gone, its remotes kept' || fail "removal: $(ls -l /usr/bin/rclone 2>&1; grep rclone /var/spool/cron/crontabs/root)"
finish_app nginx
