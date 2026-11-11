#!/bin/sh
# The Tasks app from its package (tests/common/nas.sh): the example tasks on a first install, tasks added and changed on
# its page and kept in cron (root's crontab and WD's own list, a stand-in xmldbc), runs (output, exit codes, time limits
# stopping what a task started, one run at a time, stopping from the page), boot tasks once per boot, shutdown tasks,
# switched off, ntfy messages, removal
. /t/common/nas.sh tasks
CTL=$P/tasks/tasks_ctl.sh
CRON=/var/spool/cron/crontabs/root
# A task's field from the page's status: field <id> <php expression on $t>
field() { get status | php -r '$d=json_decode(stream_get_contents(STDIN),true); foreach ($d["tasks"] as $t) if ($t["id"] === $argv[1]) echo json_encode(eval("return $argv[2];"), JSON_UNESCAPED_SLASHES);' "$1" "$2"; }
# Waits (up to 20 seconds) for a task's run to end
settle() { i=0; while [ $i -lt 20 ] && [ "$(field "$1" '$t["running"]')" = true ]; do sleep 1; i=$((i + 1)); done; }
# Adds a task from the page: add <name> <trigger> <schedule> <script> [timeout] [notify] - prints its ID
add() { post save --data-urlencode "name=$1" -d "trigger=$2" --data-urlencode "schedule=$3" --data-urlencode "script=$4" -d "timeout=${5:-30}" -d "notify=${6:-never}" -d enabled=1 | j '$d["id"] ?? $d["error"]' | tr -d '"'; }
# Whether a process is running, by part of its command line
alive() { ps | grep -v grep | grep -q "$1"; }

echo '== first install'
install_app
[ "$(stat -c '%U %a' $D)" = 'root 700' ] && [ "$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true));' $D/tasks.json)" = 2 ] \
    && [ "$(php -r 'foreach (json_decode(file_get_contents($argv[1]), true) as $t) if ($t["enabled"]) echo "on";' $D/tasks.json)" = '' ] \
    && pass 'its data folder root'"'"'s only, the 2 examples there, switched off' || fail "install: $(ls -la $D; cat $D/tasks.json)"
grep -q '# tasks-daily$' $CRON && xmldbc --crontab | grep -q '# tasks-daily$' && [ "$(grep -c '# tasks-' $CRON)" = 1 ] \
    && pass 'only its own daily job in cron (crontab and WD'"'"'s list)' || fail "cron: $(cat $CRON)"

echo '== its page'
page_up tasks
ST=$(get status)
[ "$(echo "$ST" | j '$d["active"]')" = true ] && [ "$(echo "$ST" | j 'count($d["tasks"])')" = 2 ] && [ "$(echo "$ST" | j '$d["ntfy"]["installed"]')" = false ] \
    && pass 'status: on, 2 tasks, no ntfy app' || fail "status: $(echo "$ST" | head -c 400)"
E=$(echo "$ST" | j '$d["tasks"][0]["id"]' | tr -d '"')
post script -d id=$E | j '$d["script"]' | grep -q 'rsync -a' && pass 'an example'"'"'s script shown' || fail 'script'

echo '== a scheduled task'
A=$(add 'Hello' schedule '*/5 * * * *' "$(printf '#!/bin/sh\r\necho "hello $TASK_NAME ($TASK_REASON)"\r\npwd\r\n')")
echo "$A" | grep -q '^[0-9a-f]\{8\}$' && ! grep -q "$(printf '\r')" $D/scripts/$A.sh && [ "$(stat -c '%a' $D/scripts/$A.sh)" = 700 ] \
    && pass 'saved (its CR LF lines made LF, its script root'"'"'s only)' || fail "save: $A"
grep -q "^\*/5 \* \* \* \* sh $P/tasks/tasks_ctl.sh run $A schedule > /dev/null 2>&1 # tasks-$A\$" $CRON \
    && xmldbc --crontab | grep -q "# tasks-$A\$" && pass 'in cron: root'"'"'s crontab and WD'"'"'s list' || fail "cron: $(cat $CRON); $(xmldbc --crontab)"
R=$(post save -d name=Bad -d trigger=schedule --data-urlencode 'schedule=61 * * * *' -d script=true -d timeout=5 -d enabled=1)
echo "$R" | j '$d["error"]' | grep -q "minute isn't valid" && pass 'a wrong schedule refused' || fail "bad schedule: $R"
R=$(post save -d id=$A -d name='Hello again' -d trigger=schedule --data-urlencode 'schedule=0 3 * * 1' --data-urlencode "script=echo again" -d timeout=5 -d enabled=1)
[ "$(echo "$R" | j '$d["id"]')" = "\"$A\"" ] && grep -q "^0 3 \* \* 1 .* # tasks-$A\$" $CRON && [ "$(grep -c "# tasks-$A\$" $CRON)" = 1 ] \
    && [ "$(xmldbc --crontab | grep "# tasks-$A\$" | cut -d ' ' -f 1-5)" = '0 3 * * 1' ] && pass 'changed: its new schedule in cron, once' \
    || fail "change: $R $(grep tasks- $CRON)"

echo '== runs'
post save -d id=$A -d name=Hello -d trigger=manual --data-urlencode "script=$(printf '#!/bin/sh\necho "hello $TASK_NAME ($TASK_REASON)"\npwd')" -d timeout=5 -d enabled=1 > /dev/null
! grep -q "# tasks-$A\$" $CRON && ! xmldbc --crontab | grep -q "# tasks-$A\$" && pass 'made a run-by-hand task: out of cron' || fail 'manual still in cron'
post run -d id=$A > /dev/null; sleep 1; settle $A
[ "$(field $A '$t["status"]["state"]')" = '"ok"' ] && post output -d id=$A | j '$d["output"]' | grep -q 'hello Hello (manual)' \
    && [ "$(post output -d id=$A | j 'in_array("/", $d["output"])')" = true ] && grep -q 'Hello (manual): ok, exit code 0' $D/history.log \
    && pass 'run from the page: done, its output (TASK_NAME, TASK_REASON, run in /), in the history' || fail "run: $(field $A '$t'); $(post output -d id=$A)"
B=$(add 'Fails' manual '' "$(printf 'echo oops\nexit 3')")
post run -d id=$B > /dev/null; sleep 1; settle $B
[ "$(field $B '$t["status"]["state"]')" = '"failed"' ] && [ "$(field $B '$t["status"]["code"]')" = 3 ] \
    && pass 'a failing script: failed, exit code 3' || fail "failed: $(field $B '$t')"
C=$(add 'Too long' manual '' "$(printf 'sleep 301 &\nsleep 302')" 1)
TASKS_TEST_MINUTE=2 sh $CTL run $C manual
[ "$(field $C '$t["status"]["state"]')" = '"timeout"' ] && ! alive 'sleep 301' && ! alive 'sleep 302' \
    && pass 'over its time limit: stopped, with what it started' || fail "timeout: $(field $C '$t'); $(ps | grep sleep)"
F=$(add 'Slow' manual '' 'sleep 303')
post run -d id=$F > /dev/null; sleep 2
[ "$(field $F '$t["running"]')" = true ] && ! sh $CTL run $F manual && grep -q "Slow (manual): skipped - it's still running" $D/history.log \
    && pass 'one run at a time (a second run skipped)' || fail "lock: $(field $F '$t')"
[ "$(post delete -d id=$F | j '$d["ok"]')" = false ] && pass 'a running task can'"'"'t be removed' || fail 'removed while running'
R=$(post stop -d id=$F); sleep 1; settle $F
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! alive 'sleep 303' && [ "$(field $F '$t["status"]["state"]')" = '"failed"' ] \
    && post output -d id=$F | grep -q 'Stopped from its page' && pass 'stopped from the page' || fail "stop: $R $(cat $D/status/$F.json)"

echo '== switched off, removed'
post save -d id=$F -d name=Slow -d trigger=schedule --data-urlencode 'schedule=15 1 * * *' -d script='sleep 303' -d timeout=5 -d enabled=1 > /dev/null
R=$(post enable -d id=$F -d enabled=0)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! grep -q "# tasks-$F\$" $CRON && ! xmldbc --crontab | grep -q "# tasks-$F\$" \
    && pass 'a task switched off: out of cron' || fail "off: $R"
post enable -d id=$F -d enabled=1 > /dev/null
grep -q "# tasks-$F\$" $CRON && pass 'and on again: back in cron' || fail 'on'
R=$(post delete -d id=$F)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && ! grep -q "# tasks-$F\$" $CRON && ! xmldbc --crontab | grep -q "# tasks-$F\$" && [ ! -f $D/scripts/$F.sh ] \
    && pass 'removed: its script and cron job gone' || fail "delete: $R"

echo '== ntfy'
mkdir -p $P/ntfy $P/_ntfy && echo tk_testtoken > $P/_ntfy/token
cat > /tmp/ntfy.php <<'EOF'
<?php
file_put_contents('/tmp/ntfy.txt', $_SERVER['REQUEST_URI'].'|'.($_SERVER['HTTP_AUTHORIZATION'] ?? '').'|'.($_SERVER['HTTP_TITLE'] ?? '').'|'.file_get_contents('php://input')."\n", FILE_APPEND);
EOF
(php -S 127.0.0.1:2586 /tmp/ntfy.php > /dev/null 2>&1 &); sleep 1
R=$(post settings -d topic='bad topic!')
[ "$(echo "$R" | j '$d["ok"]')" = false ] && [ "$(post settings -d topic=nas | j '$d["ok"]')" = true ] \
    && [ "$(get status | j '$d["ntfy"]')" = '{"installed":true,"topic":"nas"}' ] && pass 'a topic set (a bad one refused)' || fail "topic: $R"
post save -d id=$B -d name=Fails -d trigger=manual --data-urlencode "script=$(printf 'echo oops\nexit 3')" -d timeout=5 -d notify=failed -d enabled=1 > /dev/null
sh $CTL run $A manual; sh $CTL run $B manual
grep -q '^/nas|Bearer tk_testtoken|Tasks: Fails|Failed (exit code 3)' /tmp/ntfy.txt && ! grep -q 'Tasks: Hello' /tmp/ntfy.txt \
    && grep -q '^oops' /tmp/ntfy.txt && pass 'ntfy told when it failed, with its output (not about a task that doesn'"'"'t ask)' || fail "ntfy: $(cat /tmp/ntfy.txt)"

echo '== boot and shutdown'
G=$(add 'At boot' boot '' 'date >> /tmp/booted')
H=$(add 'At shutdown' shutdown '' 'date >> /tmp/shutdown-ran')
sh $P/tasks/stop.sh $P/tasks > /dev/null 2>&1
[ ! -f /tmp/shutdown-ran ] && ! grep -q '# tasks-' $CRON && ! xmldbc --crontab | grep -q '# tasks-' \
    && [ "$(get status | j '$d["active"]')" = false ] && pass 'switched off: nothing in cron, no shutdown task (the NAS isn'"'"'t shutting down)' \
    || fail "stop: $(grep tasks- $CRON)"
rm -f /var/run/tasks.booted; sh $P/tasks/start.sh $P/tasks > /dev/null 2>&1; sleep 3
[ "$(wc -l < /tmp/booted 2>/dev/null)" = 1 ] && grep -q '# tasks-daily$' $CRON && pass 'started at boot: its boot task ran, its jobs back in cron' \
    || fail "boot: $(cat /tmp/booted 2>&1)"
sh $P/tasks/stop.sh $P/tasks > /dev/null 2>&1; sh $P/tasks/start.sh $P/tasks > /dev/null 2>&1; sleep 3
[ "$(wc -l < /tmp/booted)" = 1 ] && pass 'switched off and on again: not run again (once per boot)' || fail "boot again: $(cat /tmp/booted)"
printf 'sleep 30\n' > /tmp/shutdown.sh; (sh /tmp/shutdown.sh &); sleep 1
sh $P/tasks/stop.sh $P/tasks > /dev/null 2>&1
sh $P/tasks/start.sh $P/tasks > /dev/null 2>&1; sh $P/tasks/stop.sh $P/tasks > /dev/null 2>&1
[ "$(wc -l < /tmp/shutdown-ran 2>/dev/null)" = 1 ] && pass 'the NAS shutting down (WD'"'"'s shutdown.sh running): its shutdown task ran, once though stopped twice' \
    || fail "shutdown: $(cat /tmp/shutdown-ran 2>&1) $(ps | grep shutdown)"
rm -f /var/run/tasks.shutdown
pkill -f /tmp/shutdown.sh 2>/dev/null
sh $P/tasks/start.sh $P/tasks > /dev/null 2>&1

echo '== removal'
finish_app
! grep -q '# tasks-' $CRON && ! xmldbc --crontab | grep -q '# tasks-' && [ -f $D/scripts/$A.sh ] \
    && pass 'its cron jobs gone (crontab and WD'"'"'s list), its tasks kept' || fail "left behind: $(grep tasks- $CRON)"
