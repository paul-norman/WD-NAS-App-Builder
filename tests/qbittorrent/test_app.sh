#!/bin/sh
# qBittorrent from its package (tests/common/nas.sh), with the Nginx app: its own user in the share group, its downloads
# folder made in the shares, nothing without its login, a torrent of a file already in the downloads folder found
# complete, files it writes changeable by the share group, the page (status, the password, settings: the folder - only
# in the shares - peer port, limits, the network), kept across a restart, its site through Nginx, removal
. /t/common/nas.sh qbittorrent
DOMAIN=nas.example.test
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip
Q=http://127.0.0.1:8092
# Its Web API, logged in as admin with a password (default: the app's): login [password] keeps the session in a cookie
# jar; api <path> [curl options]
login() { rm -f /tmp/jar; curl -s -m 5 -c /tmp/jar -H "Referer: $Q/" --data-urlencode username=admin --data-urlencode "password=${1:-$(cat $D/password)}" "$Q/api/v2/auth/login" -o /dev/null -w '%{http_code}'; }
api() { p=$1; shift; curl -s -m 10 -b /tmp/jar -H "Referer: $Q/" "$@" "$Q/api/v2/$p"; }
pref() { api app/preferences | j "\$d['$1']"; }
site() { p=$1; shift; curl -sk -m 10 --resolve "qbittorrent.$DOMAIN:443:127.0.0.1" "$@" "https://qbittorrent.$DOMAIN$p"; }
# Where something listens on a TCP port: all (0.0.0.0 / [::]) or local (127.0.0.1 only)
bound() {
    awk -v port="$(printf '%04X' "$1")" 'FNR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print l[1] }' /proc/net/tcp /proc/net/tcp6 \
        | sed 's/^0*$/all/; s/^0100007F$/local/' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# A torrent of one file (pieces of 256KB): mktorrent <file> <torrent>
mktorrent() {
    php -r '$f = $argv[1]; $size = filesize($f); $len = 262144; $pieces = ""; $h = fopen($f, "rb");
        while (!feof($h)) { $b = fread($h, $len); if ($b !== "" && $b !== false) { $pieces .= sha1($b, true); } }
        $s = function ($v) { return strlen($v).":".$v; };
        $info = "d6:lengthi".$size."e4:name".$s(basename($f))."12:piece lengthi".$len."e6:pieces".$s($pieces)."e";
        file_put_contents($argv[2], "d8:announce".$s("udp://tracker.invalid:1337/announce")."4:info".$info."e");' "$1" "$2"
}

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== installed and started'
install_app
wait_port 8092 60 && pass 'answering on 8092' || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/console.log)"; exit 1; }
PID=$(cat /var/run/qbittorrent.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 84 ] && [ "$(awk '/^Gid:/ { print $2 }' /proc/$PID/status)" = 1000 ] \
    && [ "$(stat -c '%U %a' $D/profile)" = 'qbittorrent 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] && [ "$(stat -c '%u %a' $D/settings)" = '0 600' ] \
    && pass "runs as its own user (84) in the share group, its data its own, the password and settings root's" \
    || fail "user: $(grep -E '^(Uid|Gid):' /proc/$PID/status | tr '\n' ' ') $(ls -la $D)"
DL=$V/Public/Downloads
[ -d $DL ] && [ "$(stat -c '%U %G %a' $DL)" = 'qbittorrent share 2775' ] && grep -q "^DOWNLOAD_DIR=$DL$" $D/settings \
    && pass "its downloads folder made in the shares: $DL (the share group's)" || fail "downloads: $(ls -ld $DL) $(cat $D/settings)"
CONF=$D/profile/qBittorrent/config/qBittorrent.conf
grep -q '^Password_PBKDF2="@ByteArray(' $CONF && ! grep -q "$(cat $D/password)" $CONF && ! grep -q 'temporary password' $D/console.log \
    && pass "its login set in qBittorrent.conf, the password only hashed there (PBKDF2), no temporary password" || fail "conf: $(grep WebUI $CONF) $(tail -n 3 $D/console.log)"

echo '== nothing without its login'
C=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$Q/api/v2/app/version"); [ "$C" = 403 ] && pass "its API refuses a request without the login, even from the NAS itself ($C)" || fail "no login: $C"
login wrong-password > /dev/null; C=$(api app/version -o /dev/null -w '%{http_code}'); [ "$C" = 403 ] && pass "and with a wrong password ($C)" || fail "wrong password: $C"
C=$(login); V_=$(api app/version)
[ "$C" = 200 ] || [ "$C" = 204 ] && [ "$V_" = v5.3.0 ] && pass "its API with the login: qBittorrent $V_" || fail "login: $C $V_"
curl -s -m 5 "$Q/" | grep -qi '<title>qBittorrent' && pass 'its web interface (its login form)' || fail "web: $(curl -s -m 5 $Q/ | head -c 200)"
[ "$(pref save_path)" = "\"$DL\"" ] && [ "$(pref listen_port)" = 6882 ] && [ "$(pref web_ui_port)" = 8092 ] && [ "$(pref web_ui_host_header_validation_enabled)" = false ] \
    && pass "its settings from the app: $DL, peer port 6882, web interface 8092 (any host name)" || fail "prefs: $(pref save_path) $(pref listen_port)"

echo '== a torrent'
head -c 3000000 /dev/urandom > $DL/test-file.bin 2>/dev/null || dd if=/dev/zero of=$DL/test-file.bin bs=1M count=3 2>/dev/null
mktorrent $DL/test-file.bin /tmp/test.torrent
api torrents/add -F torrents=@/tmp/test.torrent > /dev/null
i=0; while [ $i -lt 30 ] && [ "$(api torrents/info | j '$d[0]["progress"] ?? 0')" != 1 ]; do sleep 2; i=$((i + 1)); done
HASH=$(api torrents/info | j '$d[0]["hash"]' | tr -d '"')
[ "$(api torrents/info | j '$d[0]["progress"] ?? 0')" = 1 ] && pass "a torrent of a file already in the downloads folder: verified complete ($(api torrents/info | j '$d[0]["state"]'))" \
    || fail "torrent: $(api torrents/info | head -c 300)"
api torrents/setLocation -d "hashes=$HASH" --data-urlencode "location=$DL/moved" > /dev/null
i=0; while [ $i -lt 15 ] && [ ! -f $DL/moved/test-file.bin ]; do sleep 1; i=$((i + 1)); done
[ -f $DL/moved/test-file.bin ] && [ "$(stat -c '%G' $DL/moved)" = share ] && [ "$(( 0$(stat -c '%a' $DL/moved) & 020 ))" != 0 ] \
    && pass "files it writes there belong to the share group, writable by it ($(stat -c '%a %G' $DL/moved))" || fail "move: $(ls -la $DL $DL/moved 2>&1)"

echo '== its page'
page_up qbittorrent
ST=$(get status); get status > /dev/null
[ "$(echo "$ST" | j '$d["running"] && $d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"5.3.0"' ] && [ "$(echo "$ST" | j '$d["torrents"]')" = 1 ] \
    && echo "$ST" | j '$d["address"]' | grep -q ':8092/"$' && [ "$(stat -c '%u %a' $D/page_session)" = '0 600' ] \
    && pass "status: running, 5.3.0, 1 torrent, $(echo "$ST" | j '$d["address"]') (its session kept, root's only)" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password -d show=1 | j '$d["password"]')" = "\"$(cat $D/password)\"" ] && pass 'the password shown' || fail 'password'
OLD=$(cat $D/password); NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"'); wait_port 8092 30
C1=$(login "$OLD"); C2=$(login "$NEW")
[ ${#NEW} = 20 ] && [ "$NEW" != "$OLD" ] && [ "$C1" = 401 ] && { [ "$C2" = 200 ] || [ "$C2" = 204 ]; } \
    && pass "a new password: it works, the old one no longer does ($C1)" || fail "new password: ${#NEW} $C1 $C2"
[ "$(get status | j '$d["answering"]')" = true ] && pass 'the page logs in again with the new password' || fail "page after new password: $(get status | head -c 200)"
R1=$(post settings -d download_dir=$P/_qbittorrent -d peer_port=6882 -d down_limit=0 -d up_limit=0)
R2=$(post settings -d download_dir=/etc -d peer_port=6882 -d down_limit=0 -d up_limit=0)
R3=$(post settings -d download_dir=$DL -d peer_port=8092 -d down_limit=0 -d up_limit=0)
[ "$(echo "$R1" | j '$d["ok"]')" = false ] && [ "$(echo "$R2" | j '$d["ok"]')" = false ] && [ "$(echo "$R3" | j '$d["ok"]')" = false ] \
    && pass "refused: a folder in Nas_Prog ($(echo "$R1" | j '$d["error"]')), outside the shares, the web interface's port as the peer port" || fail "refusals: $R1 $R2 $R3"
mkdir -p "$V/Public/My Torrents, new"
R1=$(post settings --data-urlencode "download_dir=$V/Public/My Torrents, new" -d peer_port=51500 -d down_limit=2000 -d up_limit=300 -d listen=all); wait_port 8092 30
login > /dev/null
[ "$(echo "$R1" | j '$d["ok"]')" = true ] && [ "$(pref save_path)" = "\"$V/Public/My Torrents, new\"" ] && [ "$(pref listen_port)" = 51500 ] \
    && [ "$(pref dl_limit)" = 2048000 ] && [ "$(pref up_limit)" = 307200 ] \
    && pass 'settings saved and in use: another folder (a space and a comma in its name), peer port 51500, limits 2000 / 300 KB/s' \
    || fail "settings: $R1 $(pref save_path) $(pref listen_port) $(pref dl_limit) $(pref up_limit)"
[ "$(api torrents/info | j 'count($d)')" = 1 ] && pass 'the torrent kept across the restarts' || fail "torrent gone: $(api torrents/info | head -c 200)"
grep -c 'Password_PBKDF2' $CONF | grep -qx 1 && grep -q '^\[LegalNotice\]' $CONF && pass 'its settings file rewritten cleanly (each key once)' || fail "conf: $(cat $CONF | head -c 600)"

echo '== its site through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:8092' $P/_nginx/sites/60-app-qbittorrent.conf 2>/dev/null && site / | grep -qi '<title>qBittorrent' \
    && pass "its site https://qbittorrent.$DOMAIN/" || fail "site: $(ls $P/_nginx/sites; site / | head -c 200)"
C=$(site /api/v2/auth/login -H "Origin: https://qbittorrent.$DOMAIN" -H "Referer: https://qbittorrent.$DOMAIN/" --data-urlencode username=admin \
    --data-urlencode "password=$NEW" -c /tmp/sitejar -o /dev/null -w '%{http_code}')
V_=$(site /api/v2/app/version -b /tmp/sitejar -H "Referer: https://qbittorrent.$DOMAIN/")
{ [ "$C" = 200 ] || [ "$C" = 204 ]; } && [ "$V_" = v5.3.0 ] && pass "logging in through it ($C), as a browser does (its own origin)" || fail "site login: $C $V_"
[ "$(get status | j '$d["site"]["url"]')" = "\"https://qbittorrent.$DOMAIN/\"" ] && pass 'the page shows its site' || fail "site: $(get status | j '$d["site"]')"

echo '== the network setting'
[ "$(bound 8092)" = all ] && pass 'on the network by default' || fail "bound: $(bound 8092)"
post settings --data-urlencode "download_dir=$V/Public/My Torrents, new" -d peer_port=51500 -d down_limit=2000 -d up_limit=300 -d listen=local > /dev/null; wait_port 8092 30
[ "$(bound 8092)" = local ] && site / -f --retry 5 --retry-all-errors --retry-delay 1 | grep -qi '<title>qBittorrent' \
    && pass 'only through Nginx: on 127.0.0.1 only, its site still working' || fail "local: $(bound 8092)"

echo '== removal'
finish_app
[ ! -f $P/_nginx/sites/60-app-qbittorrent.conf ] && [ -f $DL/moved/test-file.bin ] && [ ! -f /var/run/qbittorrent.pid ] \
    && pass 'stopped, its Nginx site gone, the downloads kept' || fail "removal: $(ls $P/_nginx/sites)"
finish_app nginx
