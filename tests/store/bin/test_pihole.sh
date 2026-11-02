# The real Pi-hole recipe through the Store. First as it is: this test machine already has DNS servers on port 53 (as a
# NAS might), so its pre_install hook must stop the install with a clear message. Then a copy on other ports (made by
# run_tests.sh): DNS answered, a blocked name refused, the web interface and its password, the Nginx site, removal
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
python3 /tbin/repotool.py add-recipe /www/repo $PROJ/recipes/pihole; python3 /tbin/repotool.py add-recipe /www/repo /tfix/pihole-ports; post refresh >/dev/null
ANS='{"WEB_PASSWORD":"Test-pass-123","UPSTREAMS":"1.1.1.1;1.0.0.1","TZ":"Europe/London"}'

echo '== port 53 already in use'
post start -d job=recipe_install -d repo=$REPO -d id=pihole --data-urlencode "answers=$ANS" >/dev/null; job_wait
get job >/dev/null; LOG=$(j '$d["log"]')
[ "$JOB_STATE" = '"failed"' ] && echo "$LOG" | grep -q "Port 53 (tcp) is already used\|Port 53 (udp) is already used" && [ -z "$(docker ps -aq --filter name=^pihole$)" ] && [ ! -d $P/_pihole ] && ! echo "$LOG" | grep -q 'failed to bind' \
    && pass "refused before anything starts: port 53 is in use on this machine - $(echo "$LOG" | grep -o 'Port 53 ([a-z]*) is already used[^"\\]*' | head -n 1)" || fail "port check: $JOB_STATE $(echo "$LOG" | tail -c 400)"

echo '== installed (on ports 1053 and 18053)'
get details "&kind=recipes&repo=$REPO&id=pihole-ports" >/dev/null
echo "  problems: $(j '$d["problems"]')"
post start -d job=recipe_install -d repo=$REPO -d id=pihole-ports --data-urlencode "answers=$ANS" >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && pass "Pi-hole installed through the Store: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG"; get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | tail -20; }
D=$P/_pihole-ports
[ "$(stat -c %a $D/.env)" = 600 ] && grep -q '^WEB_PASSWORD=Test-pass-123' $D/.env && [ -d $D/etc-pihole ] && pass "its settings (.env root's only) and data in its folder in Nas_Prog" || fail "files: $(ls -la $D)"
# A DNS question over UDP to port 1053: the answer's address (or an empty answer) - $1 the name, $2 the type (1: A)
dns() { python3 - "$1" <<'PY'
import socket, struct, sys
name = sys.argv[1]
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5); s.sendto(q, ("127.0.0.1", 1053))
r = s.recv(512); flags, qd, an = struct.unpack(">HHH", r[2:8])
i = 12
while r[i]: i += r[i] + 1
i += 5
for _ in range(an):
    i += 2 if r[i] & 0xC0 == 0xC0 else 0
    t, c, ttl, l = struct.unpack(">HHIH", r[i:i + 10]); i += 10
    if t == 1: print(socket.inet_ntoa(r[i:i + 4])); break
    i += l
else:
    print("rcode=%d" % (flags & 15))
PY
}

for i in $(seq 1 30); do A=$(dns example.com 2>/dev/null); [ -n "$A" ] && [ "${A#rcode}" = "$A" ] && break; sleep 2; done
[ -n "$A" ] && [ "${A#rcode}" = "$A" ] && pass "DNS answered through Pi-hole: example.com -> $A" || fail "dns: $A; $(docker logs pihole 2>&1 | tail -n 5)"
# A name added to its deny list, through its API - logged in with the wizard's password
SID=$(curl -s -X POST -d '{"password":"Test-pass-123"}' http://127.0.0.1:18053/api/auth | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["session"]["valid"] ? $d["session"]["sid"] : "";')
[ -n "$SID" ] && [ -z "$(curl -s -X POST -d '{"password":"wrong-pass"}' http://127.0.0.1:18053/api/auth | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["session"]["sid"] ?? "";')" ] \
    && pass "its web interface and API: the wizard's password, not another" || fail 'web login'
curl -s -X POST -H "X-FTL-SID: $SID" -d '{"domain":"ads.example.org","comment":"test"}' http://127.0.0.1:18053/api/domains/deny/exact > /dev/null
sleep 2; BLOCKED=$(dns ads.example.org)
[ "$BLOCKED" = 0.0.0.0 ] && pass 'a blocked name answered with 0.0.0.0 (ads.example.org, on its deny list)' || fail "blocking: $BLOCKED"
[ "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1:18053/admin/)" = '302 http://127.0.0.1:18053/admin/login' ] \
    && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18053/admin/login)" = 200 ] && pass 'the dashboard answers on :18053/admin/ (its login page)' || fail 'dashboard'
SITE=$P/_nginx/sites/60-app-pihole.conf
grep -q 'proxy_pass       http://127.0.0.1:18053' $SITE 2>/dev/null && grep -q '    location / {' $SITE && grep -q 'return 302 /admin/;' $SITE \
    && pass 'Nginx pihole site: / goes to /admin/, every path passed on (its login calls /api)' || fail "nginx: $(ls $P/_nginx/sites 2>&1) $(grep location $SITE 2>&1)"

echo '== removed'
post start -d job=recipe_uninstall -d id=pihole-ports -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -z "$(docker ps -aq --filter name=^pihole$)" ] && pass "removed: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG"
true
