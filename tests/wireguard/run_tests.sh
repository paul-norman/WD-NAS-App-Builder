#!/bin/bash
# Tests the WireGuard app in stand-ins for the NAS, a phone and the home network (see README.md):
#
#     tests/wireguard/run_tests.sh [app|package|all] [--php 7.4|8.5]
#
# Default: all, on PHP 7.4. Needs Docker (containers with NET_ADMIN and /dev/net/tun, two Docker networks) and the app
# built for the PR4100 (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh wireguard, which prepares static/wireguard first). Work
# files go in $WG_TEST_WORK (default: $TMPDIR/wireguard-tests)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${WG_TEST_WORK:-${TMPDIR:-/tmp}/wireguard-tests}"
WHAT="${1:-all}"
PHP='7.4'
[ "${2:-}" = '--php' ] && PHP="${3:-7.4}"

case "${WHAT}" in
    all) TESTS='app package' ;;
    app|package) TESTS="${WHAT}" ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

case "${PHP}" in
    7.4) BASE=nas-test-php74 ;;
    8.5) BASE=nas-test-php85 ;;
    *) echo '--php is 7.4 or 8.5'; exit 1 ;;
esac

VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/wireguard/apkg.rc" | tr -d '\r')"
# Its static build is for the upstream version: the app's without its packaging revision, e.g. 1.2.3-1
STATIC="${PROJ}/packages/static/wireguard/$(echo "${VERSION}" | sed 's/-[0-9]*$//')/amd64"
PACKAGE="${PROJ}/packages/wireguard/${VERSION}/wireguard_${VERSION}_amd64.tar.gz"

if [ ! -x "${STATIC}/wireguard-go" ] || [ ! -f "${PACKAGE}" ]; then
    echo "Build WireGuard ${VERSION} first: MODEL_OVERRIDE=MyCloudPR4100 ./build.sh wireguard"

    exit 1
fi

# The test images: the suites' PHP image (built once), plus legacy iptables (as WD's NAS has)
for version in 74 85; do
    if [ "nas-test-php${version}" = "${BASE}" ] && ! docker image inspect "${BASE}" > /dev/null 2>&1; then
        docker build -q -t "${BASE}" -f "${PROJ}/tests/images/php${version}.Dockerfile" "${PROJ}/tests/images" > /dev/null
    fi
done

IMAGE="${BASE}-wg"
docker build -q -t "${IMAGE}" --build-arg "BASE=${BASE}" -f "${HERE}/image.Dockerfile" "${HERE}" > /dev/null || exit 1

# The app's files (as the build puts them together), BusyBox with its user tools and ip (static)
mkdir -p "${WORK}"
docker run --rm -v "${WORK}:${WORK}" busybox:1.36 rm -rf "${WORK}/app"
mkdir -p "${WORK}/app" "${WORK}/bb"
cp -r "${PROJ}/apps/wireguard/." "${WORK}/app/"
cp "${PROJ}/apps/helpers.sh" "${PROJ}/apps/apkg_helpers.sh" "${WORK}/app/"
cp "${PROJ}/apps/manage_helpers.php" "${WORK}/app/manage/"
[ -x "${WORK}/bb/busybox" ] || docker run --rm -v "${WORK}/bb:/out" busybox:1.36-musl cp /bin/busybox /out/busybox

PASSES=0
FAILS=0
pass() { echo "PASS $1"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
cleanup() {
    # WG_TEST_KEEP=1 leaves the containers running, to look into a failure
    [ "${WG_TEST_KEEP:-}" = 1 ] && [ "${1:-}" != first ] && return
    docker rm -f wgt-nas wgt-phone wgt-home wgt-pkg > /dev/null 2>&1
    docker network rm wgt-home-net wgt-internet > /dev/null 2>&1
}
cleanup
# Privileged: containers can only change IP forwarding - /proc/sys - when privileged
CAPS=(--privileged --init)

run_app() {
    # The home network (the NAS and a device on it) and the internet (the NAS and a phone)
    docker network create --subnet 192.168.77.0/24 wgt-home-net > /dev/null
    docker network create --subnet 172.31.77.0/24 wgt-internet > /dev/null
    # A device at home: answers with the address it sees requests come from
    docker run -d --name wgt-home --network wgt-home-net --ip 192.168.77.3 "${BASE}" sh -c \
        'mkdir -p /www && echo "<?php echo \$_SERVER[\"REMOTE_ADDR\"];" > /www/index.php && php -S 0.0.0.0:80 -t /www' > /dev/null
    docker run -d --name wgt-nas "${CAPS[@]}" --network wgt-home-net --ip 192.168.77.2 -v "${HERE}/bin:/t/bin:ro" \
        -v "${WORK}/bb:/t/bb:ro" -v "${WORK}/app:/app:ro" -v "${STATIC}:/mnt/HD/HD_a2/Nas_Prog/wireguard/binaries:ro" \
        "${IMAGE}" sleep infinity > /dev/null
    docker network connect --ip 172.31.77.2 wgt-internet wgt-nas
    docker run -d --name wgt-phone "${CAPS[@]}" --network wgt-internet --ip 172.31.77.3 -v "${WORK}/bb:/t/bb:ro" \
        -v "${STATIC}:/wg:ro" "${IMAGE}" sleep infinity > /dev/null
    docker exec wgt-nas sh /t/bin/nas.sh > "${WORK}/nas-setup.log" 2>&1

    nas() { docker exec wgt-nas sh -c ". /t/bin/env.sh; $1"; }
    phone() { docker exec wgt-phone sh -c "PATH=/tmp/bb:\$PATH; $1"; }
    api_get() { nas "get $1"; }
    api() { local a=$1; shift; docker exec wgt-nas sh -c '. /t/bin/env.sh; a=$1; shift; post "$a" "$@"' sh "${a}" "$@"; }
    j() { docker exec -i wgt-nas php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
    # The phone: the device's configuration from the page, brought up as the WireGuard app would
    phone_up() {
        api peer_config -d "id=$1" | docker exec -i wgt-nas php -r 'echo json_decode(stream_get_contents(STDIN),true)["config"];' > "${WORK}/phone.conf"
        docker cp "${WORK}/phone.conf" wgt-phone:/tmp/phone.conf
        phone 'mkdir -p /tmp/bb && ln -sf /t/bb/busybox /tmp/bb/ip; pkill -x wireguard-go; sleep 1
			grep -v -E "^(Address|DNS) =" /tmp/phone.conf > /tmp/wg.conf
			address=$(sed -n "s/^Address = //p" /tmp/phone.conf)
			(WG_PROCESS_FOREGROUND=1 /wg/wireguard-go wg0 > /tmp/wg.log 2>&1 &); sleep 1
			/wg/wg setconf wg0 /tmp/wg.conf && ip address add "$address" dev wg0 && ip link set dev wg0 mtu 1420 up
			for route in $(sed -n "s/^AllowedIPs = //p" /tmp/phone.conf | tr -d " " | tr "," " "); do
				# (everything: the VPN and the home network, standing in for the whole internet)
				case "$route" in */0) [ "${route#*:}" = "$route" ] && ip route add 10.0.0.0/8 dev wg0 && ip route add 192.168.77.0/24 dev wg0 ;; *) ip route add "$route" dev wg0 ;; esac
			done'
    }
    reach() { phone "curl -s -m 4 $1"; }
    # After a change on the NAS, a phone renews its connection within seconds, as WireGuard does
    reach_soon() { local i; for i in 1 2 3 4 5 6; do r=$(reach "$1"); [ -n "$r" ] && { echo "$r"; return; }; sleep 2; done; }

    echo '== the app: start, settings'
    nas 'sh $A/wg_ctl.sh start' > "${WORK}/start.log" 2>&1
    [ "$(nas 'ip -4 address show wg0' | grep -o '10\.8\.0\.1/24')" = '10.8.0.1/24' ] && pass 'wg0 up at 10.8.0.1/24 (wireguard-go)' || { fail "no wg0: $(cat "${WORK}/start.log")"; return; }
    ST=$(api_get status)
    [ "$(echo "$ST" | j '$d["running"]')" = true ] && [ "$(echo "$ST" | j '$d["lan"]["subnet"]')" = '"192.168.77.0/24"' ] \
        && echo "$ST" | j '$d["tools_version"]' | grep -q '"1\.0\.' \
        && pass "status: running (wireguard-go $(echo "$ST" | j '$d["version"]'), wg $(echo "$ST" | j '$d["tools_version"]')), home network $(echo "$ST" | j '$d["lan"]')" || fail "status: ${ST:0:300}"
    [ "$(nas 'code -H "X-Requested-With: XMLHttpRequest" $B/api.php?action=status')" = 403 ] && \
        [ "$(nas 'code -H "$CK" -H "X-Requested-With: XMLHttpRequest" -H "X-CSRF-Token: wrong" -X POST -d name=x $B/api.php?action=add_peer')" = 403 ] \
        && pass 'without a NAS login, or with a wrong CSRF token: refused' || fail 'auth'
    api add_peer -d 'name=Too soon' | grep -q 'First set the address' && pass 'no devices before the address they connect to is set' || fail 'device without an endpoint'
    api settings -d endpoint=172.31.77.2 -d port=80 -d access=lan -d subnet=10.8.0.0/24 -d dns= | grep -q 'between 1024' \
        && api settings -d endpoint=172.31.77.2 -d port=51820 -d access=lan -d subnet=192.168.77.0/24 -d dns= | grep -q 'overlaps' \
        && api settings -d 'endpoint=bad name!' -d port=51820 -d access=lan -d subnet=10.8.0.0/24 -d dns= | grep -q 'domain name' \
        && api settings -d endpoint=172.31.77.2 -d port=51820 -d access=lan -d subnet=10.8.0.0/24 -d dns=1.2.3 | grep -q 'DNS servers' \
        && pass 'refused: a port below 1024, a range overlapping the home network, a bad address, a bad DNS server' || fail 'settings checks'
    api settings -d endpoint=172.31.77.2 -d port=51820 -d access=lan -d subnet=10.8.0.0/24 -d dns=192.168.77.1 | grep -q '"ok":true' \
        && pass 'settings saved' || fail 'settings'

    echo '== a phone, through the tunnel'
    ID=$(api add_peer -d "name=Test phone" | j '$d["id"]' | tr -d '"')
    config() { api peer_config -d "id=$1" | docker exec -i wgt-nas php -r 'echo json_decode(stream_get_contents(STDIN),true)["config"];'; }
    C=$(api peer_config -d "id=${ID}")
    CT=$(config "${ID}")
    echo "$CT" | grep -q 'Endpoint = 172.31.77.2:51820' && echo "$CT" | grep -q 'AllowedIPs = 10.8.0.0/24, 192.168.77.0/24' \
        && echo "$CT" | grep -q 'DNS = 192.168.77.1' && echo "$CT" | grep -q 'PresharedKey' && pass "the device's configuration: its address, the NAS, the home network, DNS, a preshared key" || fail "config: ${C:0:400}"
    [ "$(echo "$C" | j '$d["qr"]' | tr -d '"' | base64 -d 2>/dev/null | head -c 200 | grep -c '<svg')" = 1 ] && pass 'its QR code (SVG)' || fail 'no QR code'
    phone_up "${ID}"
    [ "$(reach http://10.8.0.1:8099/)" = 10.8.0.2 ] && pass 'the phone reaches the NAS in the VPN (10.8.0.1), as 10.8.0.2' || fail "NAS through the tunnel: $(phone 'cat /tmp/wg.log; /wg/wg show')"
    [ "$(reach http://192.168.77.2:8099/)" = 10.8.0.2 ] && pass 'and at its home address (192.168.77.2)' || fail "NAS's home address"
    [ "$(reach http://192.168.77.3/)" = 192.168.77.2 ] && pass "a device at home answers it - seeing the NAS's address (no route back needed)" || fail "home network: $(reach http://192.168.77.3/)"
    ST=$(api_get status)
    echo "$ST" | j '$d["peers"][0]["live"]' | grep -q '"endpoint":"172.31.77.3"' && [ "$(echo "$ST" | j '$d["now"] - $d["peers"][0]["live"]["handshake"] < 60')" = true ] \
        && pass "the page sees it connected: $(echo "$ST" | j '$d["peers"][0]["live"]')" || fail "live: $(echo "$ST" | j '$d["peers"]')"

    echo '== access, switching off, removing'
    api settings -d endpoint=172.31.77.2 -d port=51820 -d access=nas -d subnet=10.8.0.0/24 -d dns= > /dev/null
    phone_up "${ID}"
    [ "$(reach http://10.8.0.1:8099/)" = 10.8.0.2 ] && [ -z "$(reach http://192.168.77.3/)" ] && pass "the NAS only: the NAS answers, the home network doesn't" || fail 'nas only'
    config "${ID}" | grep -qx 'AllowedIPs = 10.8.0.0/24' && ! config "${ID}" | grep -q 'DNS =' && pass 'its configuration: the VPN only, no DNS' || fail 'nas-only config'
    api settings -d endpoint=172.31.77.2 -d port=51820 -d access=all -d subnet=10.8.0.0/24 -d dns= > /dev/null
    config "${ID}" | grep -q 'AllowedIPs = 0.0.0.0/0, ::/0' && [ "$(nas 'cat /proc/sys/net/ipv4/ip_forward')" = 1 ] \
        && pass "everything: all the device's traffic (IPv6 too, so it can't leak), forwarding on" || fail 'all'
    phone_up "${ID}"
    [ "$(reach http://192.168.77.3/)" = 192.168.77.2 ] && pass 'and the home network still answers' || fail 'all: home network'
    api switch_peer -d "id=${ID}" -d enabled=0 > /dev/null
    [ -z "$(reach http://10.8.0.1:8099/)" ] && pass 'switched off: cut off straight away (no restart)' || fail 'still connected after switching off'
    api switch_peer -d "id=${ID}" -d enabled=1 > /dev/null
    [ "$(reach_soon http://10.8.0.1:8099/)" = 10.8.0.2 ] && pass 'switched on again (reconnects by itself)' || fail 'switch on'
    api settings -d endpoint=172.31.77.2 -d port=51820 -d access=lan -d subnet=10.9.0.0/24 -d dns= > /dev/null
    [ "$(api_get status | j '$d["peers"][0]["address"]')" = '"10.9.0.2"' ] && pass 'a new address range: the device moves with it (10.9.0.2)' || fail 'new range'
    phone_up "${ID}"
    [ "$(reach http://10.9.0.1:8099/)" = 10.9.0.2 ] && pass 'and connects in it' || fail 'new range connect'
    api remove_peer -d "id=${ID}" > /dev/null
    [ -z "$(reach http://10.9.0.1:8099/)" ] && [ "$(api_get status | j 'count($d["peers"])')" = 0 ] && pass 'removed: cut off' || fail 'remove'

    echo '== stopping'
    nas 'sh $A/wg_ctl.sh stop' > /dev/null
    ! nas 'ip link show wg0' > /dev/null 2>&1 && ! nas 'iptables -S; iptables -t nat -S' | grep -q WIREGUARD && [ "$(nas 'cat /proc/sys/net/ipv4/ip_forward')" = 0 ] \
        && pass 'stopped: wg0 gone, its iptables rules gone, forwarding off again' || fail "stop: $(nas 'iptables -S; cat /proc/sys/net/ipv4/ip_forward')"
}

run_package() {
    docker run -d --name wgt-pkg "${CAPS[@]}" -v "${HERE}/bin:/t/bin:ro" -v "${WORK}/bb:/t/bb:ro" -v "${PACKAGE}:/pkg/package.tar.gz:ro" \
        "${IMAGE}" sleep infinity > /dev/null
    docker exec wgt-pkg sh /t/bin/test_package.sh > "${WORK}/package.log" 2>&1
    grep -E '^(PASS|FAIL)' "${WORK}/package.log" | while read -r line; do echo "${line}"; done
    PASSES=$((PASSES + $(grep -c "^PASS" "${WORK}/package.log")))
    FAILS=$((FAILS + $(grep -c "^FAIL" "${WORK}/package.log")))
}

for test in ${TESTS}; do
    echo "== ${test} (PHP ${PHP})"
    "run_${test}"
    cleanup
done

echo "   ${PASSES} passed, ${FAILS} failed (logs: ${WORK})"
[ "${FAILS}" = 0 ] && [ "${PASSES}" != 0 ]
