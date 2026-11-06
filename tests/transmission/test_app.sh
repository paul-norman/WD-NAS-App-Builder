#!/bin/sh
# Transmission from its package (tests/common/nas.sh), with the Nginx app: its own user in the share group, its downloads
# folder made in the shares, nothing without its login, a torrent made from a file in the downloads folder found
# complete and seeding, files it writes changeable by the share group, the page (status, the password, settings: the
# folder - only in the shares - peer port, limits, the network), kept across a restart, its site through Nginx, removal
. /t/common/nas.sh transmission
DOMAIN=nas.example.test
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
R=$P/transmission/binaries/bin/transmission-remote
# Transmission's RPC with the app's login (in its environment): rpc <arguments>
rpc() { TR_AUTH="admin:$(cat $D/password)" $R 127.0.0.1:9091 --authenv "$@" 2>&1; }
site() { p=$1; shift; curl -sk -m 10 --resolve "torrents.$DOMAIN:443:127.0.0.1" "$@" "https://torrents.$DOMAIN$p"; }
# Where something listens on a TCP port: all (0.0.0.0 / [::]) or local (127.0.0.1 only)
bound() {
    awk -v port="$(printf '%04X' "$1")" 'FNR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print l[1] }' /proc/net/tcp /proc/net/tcp6 \
        | sed 's/^0*$/all/; s/^0100007F$/local/' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# Waits for the torrent with the ID to be complete (up to a minute): done <id>
done_at() { i=0; while [ $i -lt 30 ]; do rpc -t "$1" -i | grep -q 'Percent Done: 100%' && return 0; sleep 2; i=$((i + 1)); done; return 1; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== installed and started'
install_app
wait_port 9091 30 && pass 'answering on 9091' || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/transmission.log)"; exit 1; }
PID=$(cat /var/run/transmission.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 97 ] && [ "$(awk '/^Gid:/ { print $2 }' /proc/$PID/status)" = 1000 ] \
    && [ "$(stat -c '%U %a' $D/config)" = 'transmission 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/settings)" = '0 600' ] \
    && pass "runs as its own user (97) in the share group, its data its own, the password and settings root's" \
    || fail "user: $(grep -E '^(Uid|Gid):' /proc/$PID/status | tr '\n' ' ') $(ls -la $D)"
DL=$V/Public/Downloads
[ -d $DL ] && [ "$(stat -c '%U %G %a' $DL)" = 'transmission share 2775' ] && grep -q "^DOWNLOAD_DIR=$DL$" $D/settings \
    && pass "its downloads folder made in the shares: $DL (the share group's)" || fail "downloads: $(ls -ld $DL) $(cat $D/settings)"
J=$D/config/settings.json
S=$(php -r '$s=json_decode(file_get_contents($argv[1]),true); echo $s["download-dir"]," ",$s["rpc-port"]," ",var_export($s["rpc-authentication-required"],true)," ",$s["peer-port"]," ",$s["umask"];' $J)
[ "$S" = "$DL 9091 true 51413 002" ] && ! grep -q "$(cat $D/password)" $J \
    && pass "its settings written into Transmission's settings.json (its password hashed there by Transmission): $S" || fail "settings.json: $S"

echo '== nothing without its login'
C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/transmission/rpc); [ "$C" = 401 ] && pass "its RPC refuses a request without the login ($C)" || fail "no login: $C"
C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u admin:wrong http://127.0.0.1:9091/transmission/web/); [ "$C" = 401 ] && pass "and its web interface a wrong password ($C)" || fail "wrong password: $C"
curl -s -m 5 -u "admin:$(cat $D/password)" http://127.0.0.1:9091/transmission/web/ | grep -qi '<title>Transmission' && pass 'its web interface with the login' || fail "web: $(curl -s -m 5 -u "admin:$(cat $D/password)" http://127.0.0.1:9091/transmission/web/ | head -c 200)"
V_=$(rpc -si | sed -n 's/.*Daemon version: *\([^ ]*\).*/\1/p'); [ "$V_" = 4.1.4 ] && pass "transmission-remote with the login: daemon $V_" || fail "remote: $(rpc -si | head -c 300)"

echo '== a torrent'
head -c 3000000 /dev/urandom > $DL/test-file.bin 2>/dev/null || dd if=/dev/zero of=$DL/test-file.bin bs=1M count=3 2>/dev/null
$P/transmission/binaries/bin/transmission-create -o /tmp/test.torrent -t udp://tracker.invalid:1337/announce $DL/test-file.bin > /dev/null 2>&1
R1=$(rpc -a /tmp/test.torrent); ID=$(rpc -l | awk '$1 ~ /^[0-9]+/ { print $1; exit }' | tr -d '*')
[ -n "$ID" ] && done_at $ID && pass "a torrent of a file already in the downloads folder: verified complete ($(rpc -t $ID -i | sed -n 's/^ *State: //p'))" \
    || fail "torrent: $R1 $(rpc -l)"
rpc -t $ID --move $DL/moved > /dev/null; sleep 3
[ -f $DL/moved/test-file.bin ] && [ "$(stat -c '%G' $DL/moved)" = share ] && [ "$(( 0$(stat -c '%a' $DL/moved) & 020 ))" != 0 ] \
    && pass "files it writes there belong to the share group, writable by it ($(stat -c '%a %G' $DL/moved))" || fail "move: $(ls -la $DL $DL/moved 2>&1)"

echo '== its page'
page_up transmission
LINES=$(wc -l < $D/transmission.log)
ST=$(get status); get status > /dev/null
REJECTED=$(tail -n +$((LINES + 1)) $D/transmission.log | grep -c 'failed authentication')
[ "$REJECTED" = 0 ] && pass "the page's status logs in from its first request (no failed logins in Transmission's log)" \
    || fail "failed logins logged by the page: $REJECTED"
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"4.1.4"' ] && [ "$(echo "$ST" | j '$d["torrents"]')" = 1 ] \
    && echo "$ST" | j '$d["address"]' | grep -q ':9091/transmission/web/"$' && pass "status: running, 4.1.4, 1 torrent, $(echo "$ST" | j '$d["address"]')" \
    || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password -d show=1 | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the password shown' || fail 'password'
OLD=$(cat $D/password); NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"'); wait_port 9091 30
[ ${#NEW} = 20 ] && [ "$NEW" != "$OLD" ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "admin:$OLD" http://127.0.0.1:9091/transmission/web/)" = 401 ] \
    && curl -s -m 5 -u "admin:$NEW" http://127.0.0.1:9091/transmission/web/ | grep -qi '<title>Transmission' \
    && pass 'a new password: it works, the old one no longer does' || fail "new password: ${#NEW}"
R1=$(post settings -d download_dir=$P/_transmission -d peer_port=51413 -d down_limit=0 -d up_limit=0)
R2=$(post settings -d download_dir=/etc -d peer_port=51413 -d down_limit=0 -d up_limit=0)
R3=$(post settings -d download_dir=$DL -d peer_port=9091 -d down_limit=0 -d up_limit=0)
[ "$(echo "$R1" | j '$d["ok"]')" = false ] && [ "$(echo "$R2" | j '$d["ok"]')" = false ] && [ "$(echo "$R3" | j '$d["ok"]')" = false ] \
    && pass "refused: a folder in Nas_Prog ($(echo "$R1" | j '$d["error"]')), outside the shares, the web interface's port as the peer port" || fail "refusals: $R1 $R2 $R3"
mkdir -p $V/Public/Torrents
R1=$(post settings -d download_dir=$V/Public/Torrents -d peer_port=51500 -d down_limit=2000 -d up_limit=300 -d listen=all); wait_port 9091 30
S=$(rpc -si)
[ "$(echo "$R1" | j '$d["ok"]')" = true ] && echo "$S" | grep -q "Download directory: $V/Public/Torrents" && echo "$S" | grep -q 'Listen port: 51500' \
    && echo "$S" | grep -q 'Download speed limit: 2 MB/s (Enabled' && echo "$S" | grep -q 'Upload speed limit: 300 kB/s (Enabled' \
    && pass 'settings saved and in use: another folder, peer port 51500, limits 2000 / 300 KB/s' || fail "settings: $R1 $(echo "$S" | grep -iE "directory|listen port|speed" | tr "\n" ";")"
rpc -l | grep -q 'test-file.bin' && pass 'the torrent kept across the restarts' || fail "torrent gone: $(rpc -l)"

echo '== its site through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:9091' $P/_nginx/sites/60-app-torrents.conf 2>/dev/null \
    && site /transmission/web/ -u "admin:$NEW" | grep -qi '<title>Transmission' && [ "$(site / -o /dev/null -w '%{redirect_url}')" = "https://torrents.$DOMAIN/transmission/web/" ] \
    && pass "its site https://torrents.$DOMAIN/ (its start page /transmission/web/)" || fail "site: $(ls $P/_nginx/sites; site /transmission/web/ -u "admin:$NEW" | head -c 200)"
[ "$(get status | j '$d["site"]["url"]')" = "\"https://torrents.$DOMAIN/\"" ] && pass 'the page shows its site' || fail "site: $(get status | j '$d["site"]')"
LINES=$(wc -l < $D/transmission.log)
C1=$(site /transmission/web/ -o /dev/null -w '%{http_code}'); C2=$(site /transmission/rpc -u admin:wrong-password -o /dev/null -w '%{http_code}')
grep -q "auth_basic_user_file $D/htpasswd" $P/_nginx/sites/60-app-torrents.conf && [ "$C1" = 401 ] && [ "$C2" = 401 ] \
    && [ "$(stat -c '%u %a' $D/htpasswd)" = '0 640' ] && [ "$(tail -n +$((LINES + 1)) $D/transmission.log | grep -c 'failed authentication')" = 0 ] \
    && pass "Nginx asks for the same login first: none or a wrong one refused there ($C1, $C2), nothing in Transmission's log" \
    || fail "Nginx login: $C1 $C2 $(stat -c '%U %G %a' $D/htpasswd) $(tail -n +$((LINES + 1)) $D/transmission.log | tail -n 2)"
[ "$(cat $D/config/queue.json 2>/dev/null)" != '' ] && ! grep -q 'queue.json' $D/transmission.log \
    && pass "no queue.json error at its starts (an empty queue made for it until Transmission writes its own)" || fail "queue: $(grep queue $D/transmission.log | tail -n 1)"

echo '== the network setting'
[ "$(bound 9091)" = all ] && pass 'on the network by default' || fail "bound: $(bound 9091)"
post settings -d download_dir=$V/Public/Torrents -d peer_port=51500 -d down_limit=2000 -d up_limit=300 -d listen=local > /dev/null; wait_port 9091 30
[ "$(bound 9091)" = local ] && site /transmission/web/ -f --retry 5 --retry-all-errors --retry-delay 1 -u "admin:$NEW" | grep -qi '<title>Transmission' \
    && pass 'only through Nginx: on 127.0.0.1 only, its site still working' || fail "local: $(bound 9091)"

echo '== removal'
finish_app
[ ! -f $P/_nginx/sites/60-app-torrents.conf ] && [ -f $DL/moved/test-file.bin ] && pass 'its Nginx site gone, the downloads kept' || fail "removal: $(ls $P/_nginx/sites)"
finish_app nginx
