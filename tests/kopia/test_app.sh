#!/bin/sh
# Kopia from its package (tests/common/nas.sh): its server with a generated password (not on its command line), a real
# backup - a filesystem repository on a share, a snapshot of a folder, a restore compared with the original - seen by
# its page, a new password, where it listens, stopping and removal
. /t/common/nas.sh kopia
U=http://127.0.0.1:51515

echo "== first start"
install_app
wait_port 51515 60 && pass "answering on 51515" || { fail "not answering: $(tail -n 10 /tmp/start.log $D/kopia.log)"; exit 1; }
PW=$(cat $D/server_password)
# (its web interface: the API also needs the page's session and CSRF token, as the app's page does it)
[ "$(code -u admin:$PW $U/)" = 200 ] && [ "$(code -u admin:wrong $U/)" = 401 ] && [ "$(code $U/)" = 401 ] \
	&& [ "$(stat -c '%U %a' $D/server_password)" = "root 600" ] && pass "its web interface: the generated password (root's only), not another, not none" || fail "auth"
KP=$(ps -o pid,args | awk '/[k]opia server start/ { print $1; exit }')
[ -n "$KP" ] && ! tr '\0' ' ' < /proc/$KP/cmdline | grep -qF "$PW" && tr '\0' '\n' < /proc/$KP/environ | grep -q "^KOPIA_SERVER_PASSWORD=" && pass "the password isn't on any process's command line (it's in the server's environment)" || fail "password on a command line"

echo "== a real backup"
mkdir -p $V/Public/Documents/sub $V/Public/backups
for i in 1 2 3; do head -c 200000 /dev/urandom > $V/Public/Documents/file$i.bin; done; echo "hello" > $V/Public/Documents/sub/note.txt
K="env HOME=$D KOPIA_CONFIG_PATH=$D/repository.config KOPIA_LOG_DIR=$D/logs KOPIA_CACHE_DIRECTORY=$D/cache KOPIA_PASSWORD=Repo-pass-123 $P/kopia/binaries/kopia"
$K repository create filesystem --path=$V/Public/backups/kopia > /tmp/create.log 2>&1 && $K snapshot create $V/Public/Documents > /tmp/snap.log 2>&1 \
	&& pass "a repository on a share, and a snapshot of a folder ($(grep -o 'Created snapshot with root [^ ]*' /tmp/snap.log | head -n 1))" || fail "backup: $(tail -n 5 /tmp/create.log /tmp/snap.log)"
SNAP=$($K snapshot list $V/Public/Documents --json 2>/dev/null | php -r 'echo json_decode(stream_get_contents(STDIN),true)[0]["id"];')
$K snapshot restore "$SNAP" /tmp/restored > /tmp/restore.log 2>&1
diff -r $V/Public/Documents /tmp/restored > /dev/null && pass "restored, identical to the original" || fail "restore: $(tail -n 3 /tmp/restore.log)"

echo "== the page"
page_up
post restart -d confirm=1 > /dev/null; wait_port 51515 30; sleep 3
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["repo"]["connected"]')" = true ] \
	&& [ "$(echo "$ST" | j '$d["sources"][0]["path"]')" = "\"$V/Public/Documents\"" ] && [ "$(echo "$ST" | j '$d["sources"][0]["size"] > 600000')" = true ] \
	&& pass "it sees the repository and the folder's last snapshot ($(echo "$ST" | j '$d["sources"][0]["size"]') bytes, $(echo "$ST" | j '$d["sources"][0]["errors"]') errors)" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password -d show=1 | j '$d["password"]' | tr -d '"')" = "$PW" ] && pass "the page shows the password" || fail "password"
NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"'); post restart -d confirm=1 > /dev/null; wait_port 51515 30; sleep 2
[ "$NEW" != "$PW" ] && [ "$(code -u admin:$NEW $U/)" = 200 ] && [ "$(code -u admin:$PW $U/)" = 401 ] \
	&& pass "a new password (after its restart): the new one works, the old one doesn't" || fail "new password"
post listen -d listen=local > /dev/null; wait_port 51515 30; sleep 1
[ "$(get status | j '$d["listen"]')" = '"local"' ] && grep -q "address=http://127.0.0.1:51515" /proc/$(cat /var/run/kopia.pid 2>/dev/null)/cmdline 2>/dev/null \
	|| ps -o args | grep -q '[a]ddress=http://127.0.0.1:51515' && pass "only through the Nginx app: on 127.0.0.1" || fail "listen: $(ps -o args | grep '[k]opia server')"

echo "== removed"
finish_app
[ -d $V/Public/backups/kopia ] && pass "the repository on the share untouched" || fail "repository gone"
