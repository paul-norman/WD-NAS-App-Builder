#!/bin/sh
# k3s from its package (tests/common/nas.sh), as a real single-node cluster in a privileged container: its commands
# linked, the kubelet's drop-in (cgroup v1, swap, the memory kept for the NAS) in its live configuration, the node ready,
# CoreDNS, no Traefik or ServiceLB, everything on the data volume, a workload (a local-path volume, a Service found by
# its DNS name, a NodePort), the page (status, pods, a kubeconfig that works from elsewhere, settings: memory and
# ServiceLB), restarting k3s with its pods left running, the kernel module checks (wrong firmware, unknown model), a full
# stop (no pods, mounts, bridge or Kubernetes firewall rules left), and the cluster kept across a reinstall
. /t/common/nas.sh k3s
export PATH=$PATH:/sbin
K=$P/k3s/binaries/k3s
kc() { /sbin/kubectl "$@" 2>&1; }
# The NAS has ip in /sbin (BusyBox's): the stand-in only has it in the suite's own PATH, which the page doesn't get
command -v /usr/local/bin/ip > /dev/null || ln -sf /t/bb/busybox /usr/local/bin/ip
# Whether a memory amount (e.g. 123Ki) is less than a fraction of another: below <a> <b> <fraction>
below() { echo "${1%Ki} ${2%Ki} $3" | awk '{ exit !($1 != "" && $1 + 0 > 0 && $1 < $2 * $3) }'; }
errors() { grep -E 'level=(error|fatal)|^E[0-9]{4} |panic' $D/k3s.log | tail -n "${1:-30}"; }

# The test's own container is the "NAS": with cgroup v2 (WSL's kernel - WD's has v1), the cgroup root's processes move
# into a group of their own first, so that k3s can create its own (as k3d's images do)
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /sys/fs/cgroup/init
    xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control
fi

echo '== installed and started'
install_app
[ "$(readlink /sbin/kubectl)" = "$K" ] && [ "$(readlink /sbin/crictl)" = "$K" ] && [ "$(readlink /sbin/k3s)" = "$K" ] \
    && pass 'k3s, kubectl and crictl linked into /sbin' || fail "links: $(ls -l /sbin/kubectl /sbin/crictl /sbin/k3s 2>&1)"
V=$(k3s --version 2>&1 | head -n 1); echo "$V" | grep -q 'v1\.37\.2+k3s1' && pass "$V" || fail "version: $V"
kc wait --for=condition=Ready node --all --timeout=240s > /dev/null && N=$(kc get nodes -o jsonpath='{.items[0].metadata.name}') \
    && pass "the node is ready: $N ($(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'))" || fail "node: $(kc get nodes; tail -n 20 $D/k3s.log)"
[ "$N" = "$(cat $D/node_name)" ] && [ "$(readlink /etc/rancher/node)" = "$D/node" ] && [ -s $D/node/password ] \
    && pass "its name and password kept in $D (node_name, node/password - /etc is in RAM on the NAS)" || fail "node: $N $(cat $D/node_name) $(ls -l /etc/rancher)"

echo "== the kubelet's settings"
F=$D/data/agent/etc/kubelet.conf.d/50-wd-nas.conf
grep -q '^failCgroupV1: false$' $F && grep -q '^failSwapOn: false$' $F && grep -q '^  memory: [0-9]*Mi$' $F \
    && pass "drop-in written: cgroup v1 allowed, swap allowed, $(sed -n 's/^  memory: //p' $F) kept for the NAS" || fail "drop-in: $(cat $F)"
C=$(kc get --raw "/api/v1/nodes/$N/proxy/configz")
echo "$C" | grep -q '"failCgroupV1":false' && echo "$C" | grep -q '"failSwapOn":false' \
    && echo "$C" | grep -q "\"systemReserved\":{\"memory\":\"$(sed -n 's/^  memory: //p' $F)\"}" \
    && pass "the kubelet runs with them (its live configuration)" || fail "configz: $(echo "$C" | head -c 400)"
A=$(kc get node "$N" -o jsonpath='{.status.allocatable.memory}'); M=$(kc get node "$N" -o jsonpath='{.status.capacity.memory}')
below "$A" "$M" 0.6 && pass "the pods may use half the memory: $A of $M" || fail "allocatable: $A of $M"

echo '== what it runs'
# k3s creates its system deployments (and the default service account) a little after the node is ready
i=0; while [ $i -lt 60 ] && ! { kc get sa default > /dev/null && kc -n kube-system get deploy coredns local-path-provisioner > /dev/null; }; do sleep 2; i=$((i + 1)); done
kc -n kube-system rollout status deploy/coredns --timeout=300s > /dev/null && pass 'CoreDNS running' || { fail "coredns: $(kc -n kube-system get pods)"; grep -iE 'controller-manager|leader|deploy|fatal|panic|cloud-controller|Waiting' $D/k3s.log | tail -n 80; }
kc -n kube-system rollout status deploy/local-path-provisioner --timeout=300s > /dev/null && pass 'the local-path provisioner running' || fail "local-path: $(kc -n kube-system get pods)"
[ -z "$(kc get pods -A -o name | grep -i 'traefik\|svclb')" ] && [ -z "$(kc get helmcharts -A -o name 2>/dev/null | grep traefik)" ] \
    && pass 'no Traefik, no ServiceLB' || fail "traefik / servicelb: $(kc get pods -A)"
[ -d $D/data/agent/containerd ] && [ -n "$(ls $D/kubelet/pods 2>/dev/null)" ] && [ "$(readlink /var/log/pods)" = "$D/pod-logs" ] \
    && [ -n "$(ls $D/pod-logs)" ] && [ ! -e /var/lib/rancher ] && [ "$(find /var/lib/kubelet | tr '\n' ' ')" = '/var/lib/kubelet /var/lib/kubelet/device-plugins /var/lib/kubelet/device-plugins/kubelet.sock ' ] \
    && pass "on the data volume: containerd, the kubelet's pods and the pods' logs ($(du -sh $D | cut -f1)) - only the device plugin socket in /var/lib (RAM on the NAS)" \
    || fail "paths: $(ls $D $D/kubelet 2>&1) $(ls -l /var/log/pods) $(find /var/lib/rancher /var/lib/kubelet 2>&1 | head -n 20)"
grep -q 'containerd snapshotter: overlayfs' /tmp/debug_apkg && pass 'images layered with overlayfs' || fail "snapshotter: $(grep snapshotter /tmp/debug_apkg)"

echo '== a workload'
kc apply -f - > /tmp/apply.log 2>&1 <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec: {accessModes: [ReadWriteOnce], storageClassName: local-path, resources: {requests: {storage: 10Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: web, labels: {app: web}}
spec:
  containers:
    - name: web
      image: busybox:1.37
      command: [sh, -c, 'echo "hello from the NAS" > /data/index.html; exec httpd -f -p 8080 -h /data']
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: data}}]
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec: {type: NodePort, selector: {app: web}, ports: [{port: 80, targetPort: 8080, nodePort: 30080}]}
EOF
kc wait --for=condition=Ready pod/web --timeout=300s > /dev/null && pass 'a pod with a local-path volume running' || fail "web: $(cat /tmp/apply.log; kc describe pod web | tail -n 15)"
[ "$(cat $D/storage/*/index.html 2>/dev/null)" = 'hello from the NAS' ] && pass "its volume is a folder in $D/storage" || fail "storage: $(ls -R $D/storage | head)"
kc run client --image=busybox:1.37 --restart=Never --command -- wget -qO- -T 10 http://web.default.svc.cluster.local/ > /dev/null
kc wait --for=jsonpath='{.status.phase}'=Succeeded pod/client --timeout=180s > /dev/null; R=$(kc logs client); kc delete pod client > /dev/null
[ "$R" = 'hello from the NAS' ] && pass 'another pod reaches it by its Service name (CoreDNS, kube-proxy, pod network)' || fail "service: $R"
IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
R=$(curl -s -m 10 http://$IP:30080/)
[ "$R" = 'hello from the NAS' ] && pass "its NodePort on the NAS's address ($IP:30080)" || fail "nodeport: $R"

echo '== its page'
page_up k3s
ST=$(get status)
[ "$(echo "$ST" | j '$d["running"] && $d["ready"]')" = true ] && [ "$(echo "$ST" | j '$d["node"]')" = "\"$N\"" ] \
    && [ "$(echo "$ST" | j '$d["kernel"]')" = '[]' ] && [ "$(echo "$ST" | j '$d["version"]')" = '"v1.37.2+k3s1"' ] \
    && pass "status: running, $N ready, $(echo "$ST" | j '$d["version"]'), nothing missing from the kernel" || fail "status: $(echo "$ST" | head -c 400)"
echo "$ST" | j 'array_values(array_filter($d["pods"], function ($p) { return $p["name"] === "web"; }))[0]' | grep -q '"state":"Running","ready":"1/1"' \
    && echo "$ST" | j '$d["pods"]' | grep -q '"namespace":"kube-system","name":"coredns-' && pass "its pods: $(echo "$ST" | j 'count($d["pods"])') listed, with their state" \
    || fail "pods: $(echo "$ST" | j '$d["pods"]' | head -c 300)"
R=$(post kubeconfig -d show=1); echo "$R" | j '$d["kubeconfig"]' | php -r 'echo json_decode(stream_get_contents(STDIN));' > /tmp/kubeconfig
grep -q "server: https://$IP:6443" /tmp/kubeconfig && grep -q 'client-key-data' /tmp/kubeconfig \
    && $K kubectl --kubeconfig /tmp/kubeconfig get nodes -o name 2>&1 | grep -q "node/$N" \
    && pass "its kubeconfig works from elsewhere: https://$IP:6443 (the API's certificate names it)" || fail "kubeconfig: $(head -c 300 /tmp/kubeconfig)"

echo '== settings: memory and ServiceLB'
R=$(post settings -d memory=25 -d servicelb=1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && grep -q '^MEMORY=25$' $D/settings && grep -q '^SERVICELB=1$' $D/settings \
    && pass 'saved (and k3s restarted)' || fail "settings: $R"
kc wait --for=condition=Ready node --all --timeout=240s > /dev/null
A=$(kc get node "$N" -o jsonpath='{.status.allocatable.memory}')
below "$A" "$M" 0.3 && pass "the pods may now use a quarter: $A of $M" || fail "allocatable: $A of $M"
[ "$(echo "$(post settings -d memory=95 -d servicelb=1)" | j '$d["ok"]')" = false ] && grep -q '^MEMORY=25$' $D/settings \
    && pass 'a share above 90% refused' || fail "95%: $(cat $D/settings)"
kc expose pod web --name web-lb --type LoadBalancer --port 8088 --target-port 8080 > /dev/null
i=0; while [ $i -lt 60 ] && [ -z "$(kc get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" ]; do sleep 3; i=$((i + 1)); done
R=$(curl -s -m 10 --retry 10 --retry-all-errors --retry-delay 3 http://$IP:8088/)
[ "$R" = 'hello from the NAS' ] && pass "ServiceLB on: a LoadBalancer service on the NAS's own port 8088" || fail "servicelb: $R $(kc get svc,pods -A | grep -i 'svclb\|web-lb')"

echo '== restarting k3s itself leaves the pods running'
S=$(kc get pod web -o jsonpath='{.status.containerStatuses[0].containerID}')
R=$(post restart -d confirm=1)
kc wait --for=condition=Ready node --all --timeout=240s > /dev/null
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(kc get pod web -o jsonpath='{.status.containerStatuses[0].containerID}')" = "$S" ] \
    && [ "$(curl -s -m 10 http://$IP:30080/)" = 'hello from the NAS' ] && pass 'restarted from the page: the same container still serving' || fail "restart: $R $S"

echo '== kernel modules: only for their model and firmware'
mkdir -p /usr/local/modules/files && echo 'WDMyCloudPR4100' > /usr/local/modules/files/model && echo '5.30.100' > /etc/version
sh $P/k3s/k3s_ctl.sh setup > /dev/null 2>&1
grep -q '^module overlay: built for firmware 5.33.102, but this is 5.30.100$' $D/kernel && grep -q '^module xt_comment: built for firmware' $D/kernel \
    && pass "another firmware: none loaded, the page told why ($(grep -c '^module' $D/kernel) modules)" || fail "firmware: $(cat $D/kernel)"
echo 'MyCloudEX2Ultra' > /usr/local/modules/files/model
sh $P/k3s/k3s_ctl.sh setup > /dev/null 2>&1
grep -q '^module xt_statistic: no module built for this NAS (MyCloudEX2Ultra)$' $D/kernel && [ "$(get status | j 'count($d["kernel"]) > 0')" = true ] \
    && pass 'another model: none loaded, the page told why' || fail "model: $(cat $D/kernel)"
rm -f /usr/local/modules/files/model /etc/version; sh $P/k3s/k3s_ctl.sh setup > /dev/null 2>&1

echo '== stopped completely, kept across a reinstall'
finish_app
bin=$(ls -d $D/data/data/*/bin | head -n 1)
[ -z "$(pidof k3s-server k3s containerd-shim-runc-v2 2>/dev/null)" ] && [ -z "$(grep -E "/run/k3s|$D/kubelet|/run/netns/cni-" /proc/self/mounts)" ] \
    && ! ip link show cni0 > /dev/null 2>&1 && [ -z "$($bin/aux/iptables-save 2>/dev/null | grep 'KUBE-\|FLANNEL\|CNI-')" ] \
    && pass "nothing left running: no k3s, shims, mounts, bridge or Kubernetes firewall rules" \
    || fail "left: $(pidof k3s-server k3s containerd-shim-runc-v2) $(grep -cE "/run/k3s|$D/kubelet" /proc/self/mounts) mounts $($bin/aux/iptables-save 2>/dev/null | grep -c 'KUBE-') rules"
[ ! -e /sbin/kubectl ] && [ ! -e /sbin/k3s ] && [ ! -e /etc/rancher ] && [ ! -e /var/log/pods ] && [ ! -e /var/lib/kubelet ] \
    && pass 'its links, configuration and kubeconfig gone' || fail "left: $(ls -l /sbin/kubectl /sbin/k3s /var/log/pods 2>&1) $(ls -R /etc/rancher 2>&1)"
install_app
kc wait --for=condition=Ready node --all --timeout=240s > /dev/null && kc wait --for=condition=Ready pod/web --timeout=300s > /dev/null \
    && [ "$(curl -s -m 10 --retry 10 --retry-all-errors --retry-delay 3 http://$IP:30080/)" = 'hello from the NAS' ] \
    && pass 'installed again: the same cluster, its pod back with its volume' || fail "reinstalled: $(kc get pods -A)"
finish_app
