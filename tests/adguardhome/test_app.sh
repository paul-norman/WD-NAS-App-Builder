#!/bin/sh
# The AdGuard Home app from its package (tests/common/nas.sh), with the Nginx app (tests/adguardhome/with) and a device
# on the LAN (a network namespace, 10.98.0.2, on a link to the NAS's 10.98.0.1): its first start as its own user with
# its settings written by the app (no setup wizard), DNS on port 53 forwarded by the firewall to its port (from the
# device, with the device's own address in its query log; blocking and rewrites), its site through Nginx, the page
# (status, the DNS address, the password and a new one), refusing to start while something else answers on port 53,
# the forwarding following the NAS's addresses, backups, its web interface on the network and back, removal keeping its
# data and taking its firewall rules away
. /t/common/nas.sh adguardhome
# A password with what used to be refused: spaces, quotes, a backslash, ^ & and an accented letter
XPW='Tëst ^&"'"'"'\ pass 1'
# A field of the JSON on the input, decoded (password by default)
jpw() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo isset($d[$argv[1]]) ? $d[$argv[1]] : "";' "${1:-password}"; }
# Text for inside a JSON string: jstr <text> - its quotes and backslashes escaped
jstr() { php -r 'echo substr(json_encode($argv[1], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 1, -1);' "$1"; }
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
H=http://127.0.0.1:8094
CONFIG=$D/work/AdGuardHome.yaml
# iproute2's ip (BusyBox's, first in the PATH as on the NAS, has no network namespaces)
IP=/bin/ip
# A request to its API: api <password> <path> [curl options] (basic authentication, as its API allows)
api() { pw=$1; p=$2; shift 2; curl -s -m 10 -u "admin:$pw" "$@" "$H/control/$p"; }
# The HTTP status of an API request: api_code <password> <path>
api_code() { curl -s -m 10 -o /dev/null -w '%{http_code}' -u "admin:$1" "$H/control/$2"; }
# A request to its site through Nginx: site <path> [curl options]
site() { p=$1; shift; curl -sk -m 10 --resolve "adguard.$DOMAIN:443:127.0.0.1" "$@" "https://adguard.$DOMAIN$p"; }
# A DNS lookup from the device on the LAN: lan_dig <name> [server] - prints the answers (empty if none)
lan_dig() { $IP netns exec lan dig +short +time=3 +tries=1 @"${2:-10.98.0.1}" -p 53 "$1" A 2>/dev/null | grep -v '^;'; }
# Whether its web interface listens beyond the NAS itself (port 8094 = 1F9E)
web_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":1F9E") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }
# Its NAT rules (forwarding port 53)
rules() { iptables -t nat -S ADGUARDHOME 2>/dev/null | grep -- '--dport 53'; }

echo '== a device on the LAN'
$IP netns add lan && $IP link add veth-nas type veth peer name veth-lan && $IP link set veth-lan netns lan \
    && $IP addr add 10.98.0.1/24 dev veth-nas && $IP link set veth-nas up \
    && $IP netns exec lan $IP addr add 10.98.0.2/24 dev veth-lan && $IP netns exec lan $IP link set veth-lan up \
    && $IP netns exec lan $IP link set lo up && $IP netns exec lan busybox ping -c 1 -W 2 10.98.0.1 > /dev/null \
    && pass 'a device at 10.98.0.2, reaching the NAS at 10.98.0.1' || { fail 'the LAN device could not be set up'; exit 1; }
[ -z "$(lan_dig nas.home.test)" ] && pass 'no DNS on the NAS yet' || fail 'something already answers DNS'

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
[ "$(code $H/control/status)" = 401 ] && curl -s $H/login.html | grep -q '<title>Login</title>' \
    && pass 'its web interface answering on 8094' || { fail "not answering: $(tail -n 10 $D/adguardhome.log; grep adguardhome /tmp/debug_apkg | tail -n 15)"; exit 1; }
PID=$(cat /var/run/adguardhome.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 57 ] && [ "$(stat -c '%U %a' $D/work)" = 'adguardhome 700' ] \
    && [ "$(stat -c '%U' $CONFIG)" = adguardhome ] && [ "$(stat -c '%U %a' $D/admin_password)" = 'root 600' ] \
    && [ "$(stat -c '%U %a' $D/settings)" = 'root 600' ] \
    && pass 'runs as its own user (57), its settings file its own; the password and the app'"'"'s settings root'"'"'s' \
    || fail "user: $(grep '^Uid:' /proc/$PID/status) $(ls -la $D $D/work)"
! web_beyond && grep -q '^LISTEN=local$' $D/settings && grep -q '^  address: 127.0.0.1:8094$' $CONFIG \
    && pass 'its web interface only on the NAS itself - with the Nginx app installed' || fail "web interface: $(grep address $CONFIG)"
for tag in daily update-check firewall; do
    grep -q "adguardhome-$tag" /var/spool/cron/crontabs/root || fail "cron: no adguardhome-$tag"
done
pass 'its daily backup, weekly update check and 5-minute firewall check in cron'

echo '== its admin, no one else'
PW=$(cat $D/admin_password)
[ "$(api_code "$PW" status)" = 200 ] && [ "$(api_code wrong-password status)" = 401 ] && [ "$(api_code '' status)" = 401 ] \
    && pass 'its admin uses it with the page'"'"'s password (a wrong one, or none, refused)' || fail "admin: $(api_code "$PW" status)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' $H/control/install/configure)" != 200 ] \
    && ! curl -s $H/ -o /dev/null -w '%{redirect_url}' | grep -q install \
    && pass 'no setup wizard for anyone to claim it' || fail 'the setup wizard is offered'

echo '== DNS from the LAN'
api "$PW" filtering/set_rules -H 'Content-Type: application/json' -d '{"rules":["||blocked.example^"]}' > /dev/null
api "$PW" rewrite/add -H 'Content-Type: application/json' -d '{"domain":"nas.home.test","answer":"192.168.50.5"}' > /dev/null
[ "$(rules | wc -l)" -ge 2 ] && rules | grep -q -- '-d 10.98.0.1/32 -p udp .*--to-destination 10.98.0.1:5335' \
    && pass 'port 53 forwarded to its port (5335) on each of the NAS'"'"'s addresses' || fail "rules: $(iptables -t nat -S)"
[ "$(lan_dig nas.home.test)" = 192.168.50.5 ] && pass 'the LAN device'"'"'s lookup answered on port 53 (a rewrite)' \
    || fail "lookup: $(lan_dig nas.home.test); $(tail -n 5 $D/adguardhome.log)"
[ "$(lan_dig blocked.example)" = 0.0.0.0 ] && pass 'and blocked (a rule)' || fail "blocked: $(lan_dig blocked.example)"
[ "$($IP netns exec lan dig +short +tcp +time=3 +tries=1 @10.98.0.1 -p 53 nas.home.test A 2>/dev/null)" = 192.168.50.5 ] \
    && pass 'over TCP too' || fail 'lookup over TCP'
api "$PW" 'querylog?search=nas.home.test' | grep -q '"client":"10.98.0.2"' \
    && pass 'its query log shows the device'"'"'s own address' || fail "query log: $(api "$PW" 'querylog?search=nas.home.test' | head -c 300)"

echo '== its site'
grep -q 'proxy_pass *http://127.0.0.1:8094' $P/_nginx/sites/60-app-adguard.conf 2>/dev/null && site /login.html | grep -q '<title>Login</title>' \
    && [ "$(site /control/status -o /dev/null -w '%{http_code}' -u "admin:$PW")" = 200 ] \
    && pass "its site https://adguard.$DOMAIN/ (its API through it)" || fail "site: $(ls $P/_nginx/sites; site /login.html | head -c 300)"

echo '== its page'
page_up adguardhome
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"] && $d["forwarding"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"1.0.0"' ] \
    && echo "$ST" | j '$d["dns"]' | grep -q '10.98.0.1' && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://adguard.$DOMAIN/\"" ] \
    && [ "$(echo "$ST" | j '$d["admin"]')" = '"admin"' ] && [ "$(post password -d show=1 | j '$d["password"]')" = "\"$PW\"" ] \
    && pass 'status: running, AdGuard Home 1.0.0, the DNS address, its site, the admin account and its password' || fail "status: $(echo "$ST" | head -c 400)"
R=$(post new_password -d confirm=1 --data-urlencode "password=$XPW"); NEW=$(echo "$R" | jpw)
[ -n "$NEW" ] && [ "$NEW" != "$PW" ] && [ "$(api_code "$NEW" status)" = 200 ] && [ "$(api_code "$PW" status)" = 401 ] \
    && [ "$(cat $D/admin_password)" = "$NEW" ] && [ "$(lan_dig nas.home.test)" = 192.168.50.5 ] \
    && pass 'a new password from the page (the old one refused; its rules kept, DNS back)' || fail "new password: $R"

echo '== port 53 taken'
sh $P/adguardhome/adguardhome_ctl.sh stop > /dev/null 2>&1
[ -z "$(rules)" ] && [ -z "$(lan_dig nas.home.test)" ] && pass 'stopped: no forwarding left' || fail "after stop: $(rules)"
python3 -c 'import socket, time; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 53)); time.sleep(60)' &
OTHER=$!
sleep 1
! sh $P/adguardhome/adguardhome_ctl.sh start > /dev/null 2>&1 && ! [ -f /var/run/adguardhome.pid ] && [ -z "$(rules)" ] \
    && get status | j '$d["problem"]' | grep -q 'port 53' \
    && pass 'not started while something else answers on port 53 (the page says why)' || fail "started anyway: $(get status | head -c 300)"
kill $OTHER; wait $OTHER 2>/dev/null
sh $P/adguardhome/adguardhome_ctl.sh start > /dev/null 2>&1
[ "$(lan_dig nas.home.test)" = 192.168.50.5 ] && [ "$(get status | j '$d["problem"]')" = '""' ] \
    && pass 'started once port 53 was free again' || fail "restart: $(tail -n 5 $D/adguardhome.log)"

echo '== the NAS'"'"'s addresses'
$IP addr add 10.98.1.1/24 dev veth-nas && $IP netns exec lan $IP addr add 10.98.1.2/24 dev veth-lan
sh $P/adguardhome/adguardhome_ctl.sh firewall > /dev/null 2>&1
[ "$(lan_dig nas.home.test 10.98.1.1)" = 192.168.50.5 ] && pass 'a new address forwarded too (the 5-minute check)' || fail "new address: $(rules)"
$IP addr del 10.98.1.1/24 dev veth-nas
sh $P/adguardhome/adguardhome_ctl.sh firewall > /dev/null 2>&1
! rules | grep -q '10.98.1.1' && [ "$(lan_dig nas.home.test)" = 192.168.50.5 ] && pass 'and a gone one dropped' || fail "old address: $(rules)"

echo '== backups'
R=$(post backup -d confirm=1)
F=$(ls $D/backups/adguardhome-*.tar.gz 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(stat -c '%a' "$F")" = 600 ] && tar -xzOf "$F" AdGuardHome.yaml | grep -q 'nas.home.test' \
    && pass 'a backup from the page, root'"'"'s only, with its settings (the rewrite) in it' || fail "backup: $R $(ls -la $D/backups)"
post settings -d listen=local -d backup_keep=2 > /dev/null
for i in 1 2 3; do sleep 1; sh $P/adguardhome/adguardhome_ctl.sh backup > /dev/null 2>&1; done
[ "$(ls $D/backups/adguardhome-*.tar.gz | wc -l)" = 2 ] && pass 'only the newest 2 kept' || fail "kept: $(ls $D/backups)"

echo '== on the network'
R=$(post settings -d listen=all -d backup_keep=14)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && web_beyond && [ "$(get status | j '$d["listen"]')" = '"all"' ] \
    && pass 'its web interface on the network too (0.0.0.0:8094)' || fail "listen all: $R $(grep "^  address" $CONFIG) $(grep -i ":1F9E" /proc/net/tcp /proc/net/tcp6)"
post settings -d listen=local -d backup_keep=14 > /dev/null
! web_beyond && [ "$(api_code "$NEW" status)" = 200 ] && [ "$(lan_dig nas.home.test)" = 192.168.50.5 ] \
    && pass 'and back to the NAS only (DNS still on the network)' || fail 'listen local'

echo '== removal'
finish_app
! grep -q 'adguardhome-' /var/spool/cron/crontabs/root && [ ! -f $P/_nginx/sites/60-app-adguard.conf ] && [ -f $CONFIG ] \
    && ! iptables -t nat -S 2>/dev/null | grep -q ADGUARDHOME && [ -z "$(lan_dig nas.home.test)" ] \
    && pass 'its cron lines, site and firewall rules gone, its data kept' || fail "left behind: $(iptables -t nat -S | grep ADGUARD)"
finish_app nginx
