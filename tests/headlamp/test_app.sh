#!/bin/sh
# Headlamp from its package (tests/common/nas.sh), with the k3s app's cluster (a real one, in a privileged container)
# and the Nginx app: its own user, a kubeconfig without credentials, the headlamp-admin account added through k3s's
# manifests folder, nothing without its token (and everything with it), the page (status, the token, a new one replacing
# the old), its site through Nginx, the network setting, started before k3s (as at boot), removal (the account kept)
. /t/common/nas.sh headlamp
export PATH=$PATH:/sbin
DOMAIN=nas.example.test
kc() { /sbin/kubectl "$@" 2>&1; }
# Waits (up to 4 minutes) for the cluster's node to be registered and ready: kubectl wait fails at once while there's no
# node yet (k3s registers it a little after its API answers)
node_ready() {
    i=0
    while [ $i -lt 120 ]; do
        [ "$(kc get nodes -o 'jsonpath={.items[*].status.conditions[?(@.type=="Ready")].status}')" = True ] && return 0
        sleep 2; i=$((i + 1))
    done

    return 1
}
# Headlamp's API for the cluster: api <path> [token] prints the status code (the body in /tmp/api.json)
api() { curl -s -m 10 -o /tmp/api.json -w '%{http_code}' ${2:+-H "Authorization: Bearer $2"} "http://127.0.0.1:4466/clusters/nas$1"; }
site() { p=$1; shift; curl -sk -m 10 --resolve "headlamp.$DOMAIN:443:127.0.0.1" "$@" "https://headlamp.$DOMAIN$p"; }
# Where something listens on a TCP port: all (0.0.0.0, or Go's dual-stack [::]) or local (127.0.0.1 only)
bound() {
    awk -v port="$(printf '%04X' "$1")" 'FNR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print l[1] }' /proc/net/tcp /proc/net/tcp6 \
        | sed 's/^0*$/all/; s/^0100007F$/local/' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# As in the k3s suite: the container is the "NAS", with cgroup v2 (k3s needs its root's processes moved into a group of
# their own); the NAS has ip in /sbin, the stand-in only in the suite's own PATH
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /sys/fs/cgroup/init
    xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control
fi
command -v /sbin/ip > /dev/null || ln -sf /t/bb/busybox /sbin/ip

echo '== with k3s and Nginx'
install_app k3s
node_ready && pass 'the k3s app: its node ready' || { fail "k3s: $(tail -n 20 $P/_k3s/k3s.log)"; exit 1; }
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== installed and started'
install_app
wait_port 4466 60 && pass 'answering on 4466' || { fail "not answering: $(tail -n 10 /tmp/debug_apkg; tail -n 10 $D/headlamp.log)"; exit 1; }
PID=$(cat /var/run/headlamp.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 94 ] && [ "$(stat -c '%U %a' $D/home)" = 'headlamp 700' ] && [ "$(stat -c '%U %a' $D/kubeconfig)" = 'headlamp 600' ] \
    && [ "$(stat -c '%u %a' $D/settings)" = '0 600' ] && pass "runs as its own user (94), its home and kubeconfig its own, its settings root's" \
    || fail "user: $(awk '/^Uid:/' /proc/$PID/status) $(ls -la $D)"
grep -q 'server: https://127.0.0.1:6443' $D/kubeconfig && grep -q 'certificate-authority-data: ' $D/kubeconfig && grep -q 'user: {}' $D/kubeconfig \
    && [ -z "$(grep -E 'token:|client-key-data|client-certificate-data|password' $D/kubeconfig)" ] \
    && pass 'its kubeconfig: the cluster and its certificate authority, nothing to log in with' || fail "kubeconfig: $(head -c 400 $D/kubeconfig)"
i=0; while [ $i -lt 60 ] && [ -z "$(sh $P/headlamp/headlamp_ctl.sh token 2>/dev/null)" ]; do sleep 2; i=$((i + 1)); done
TOKEN=$(sh $P/headlamp/headlamp_ctl.sh token)
[ -f $P/_k3s/data/server/manifests/headlamp-admin.yaml ] && [ -n "$(kc -n kube-system get sa headlamp-admin -o name)" ] \
    && [ "$(kc auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:kube-system:headlamp-admin)" = yes ] && [ ${#TOKEN} -gt 100 ] \
    && pass "the headlamp-admin account added by k3s from its manifests folder: cluster-admin, a token (${#TOKEN} characters)" \
    || fail "account: $(kc -n kube-system get sa,secret | grep headlamp) token ${#TOKEN}"

echo '== nothing without its token'
curl -s -m 10 http://127.0.0.1:4466/ | grep -q '<title>Headlamp' && pass 'its web frontend' || fail "frontend: $(curl -s -m 10 http://127.0.0.1:4466/ | head -c 200)"
curl -s -m 10 http://127.0.0.1:4466/config | grep -q '"name":"nas"' && pass 'the cluster found in its kubeconfig ("nas")' || fail "config: $(curl -s -m 10 http://127.0.0.1:4466/config | head -c 300)"
C=$(api /api/v1/namespaces); [ "$C" = 401 ] && pass "the cluster refuses Headlamp without a token ($C)" || fail "no token: $C $(head -c 200 /tmp/api.json)"
C=$(api /api/v1/namespaces wrongtoken); [ "$C" = 401 ] && pass "and with a wrong one ($C)" || fail "wrong token: $C"
C=$(api /api/v1/namespaces "$TOKEN"); [ "$C" = 200 ] && grep -q '"name":"kube-system"' /tmp/api.json && pass 'with the token: the namespaces listed' || fail "token: $C $(head -c 200 /tmp/api.json)"

echo '== its page'
page_up headlamp
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["answering"] && $d["cluster"] && $d["k3s"] && $d["k3s_found"]')" = true ] \
    && echo "$ST" | j '$d["address"]' | grep -q ':4466"$' && pass "status: running, the k3s app's cluster found and running, $(echo "$ST" | j '$d["address"]')" \
    || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post token -d show=1 | j '$d["token"]')" = "\"$TOKEN\"" ] && pass 'the token shown' || fail "token: $(post token -d show=1 | head -c 200)"
NEW=$(post new_token -d confirm=1 | j '$d["token"]' | tr -d '"')
# (The cluster's API server remembers a token it accepted for 10 seconds)
sleep 11
[ ${#NEW} -gt 100 ] && [ "$NEW" != "$TOKEN" ] && [ "$(api /api/v1/namespaces "$NEW")" = 200 ] && [ "$(api /api/v1/namespaces "$TOKEN")" = 401 ] \
    && pass 'a new token: it works, the old one no longer does' || fail "new token: ${#NEW} $(api /api/v1/namespaces "$NEW") $(api /api/v1/namespaces "$TOKEN")"
TOKEN=$NEW

echo '== its site through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:4466' $P/_nginx/sites/60-app-headlamp.conf 2>/dev/null && grep -q 'proxy_buffering *off' $P/_nginx/sites/60-app-headlamp.conf \
    && grep -q 'proxy_set_header Host localhost;' $P/_nginx/sites/60-app-headlamp.conf \
    && site / | grep -q '<title>Headlamp' && [ "$(site /clusters/nas/api/v1/namespaces -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN")" = 200 ] \
    && pass "its site https://headlamp.$DOMAIN/ (streamed, as localhost): the frontend, and the cluster with the token" \
    || fail "site: $(ls $P/_nginx/sites; site / | head -c 200)"
[ "$(echo "$(get status)" | j '$d["site"]["url"]')" = "\"https://headlamp.$DOMAIN/\"" ] && pass 'the page shows its site' || fail "site: $(get status | j '$d["site"]')"

echo '== the network setting'
[ "$(bound 4466)" = all ] && pass 'on the network by default' || fail "bound: $(bound 4466)"
post settings -d listen=local > /dev/null; wait_port 4466 30
[ "$(bound 4466)" = local ] && site / -f --retry 10 --retry-all-errors --retry-delay 1 | grep -q '<title>Headlamp' \
    && pass 'only through Nginx: on 127.0.0.1 only, its site still working' \
    || fail "local: $(bound 4466) $(site / -o /dev/null -w '%{http_code}') $(tail -n 5 $D/headlamp.log) $(tail -n 3 $P/_nginx/logs/error.log 2>/dev/null)"
post settings -d listen=all > /dev/null; wait_port 4466 30
[ "$(bound 4466)" = all ] && pass 'back on the network' || fail "all: $(bound 4466)"

echo '== started before k3s (as at boot)'
sh $P/headlamp/stop.sh $P/headlamp > /dev/null 2>&1; sh $P/k3s/stop.sh $P/k3s > /dev/null 2>&1
sh $P/headlamp/start.sh $P/headlamp > /dev/null 2>&1; wait_port 4466 30
[ "$(get status | j '$d["k3s"] === false && $d["cluster"] === true')" = true ] && pass 'Headlamp up while k3s is stopped (the page says so)' || fail "before k3s: $(get status | head -c 300)"
sh $P/k3s/start.sh $P/k3s > /dev/null 2>&1; node_ready
i=0; while [ $i -lt 30 ] && [ "$(api /api/v1/namespaces "$TOKEN")" != 200 ]; do sleep 2; i=$((i + 1)); done
[ "$(api /api/v1/namespaces "$TOKEN")" = 200 ] && pass 'k3s started afterwards: Headlamp reaches it without a restart' || fail "after k3s: $(api /api/v1/namespaces "$TOKEN")"

echo '== removal'
finish_app
[ ! -f $P/_nginx/sites/60-app-headlamp.conf ] && pass 'its Nginx site gone' || fail "site left: $(ls $P/_nginx/sites)"
[ -n "$(kc -n kube-system get sa headlamp-admin -o name)" ] && pass 'its account kept in the cluster (an update keeps its token; the README says how to delete it)' || fail 'account gone'
finish_app k3s
finish_app nginx
