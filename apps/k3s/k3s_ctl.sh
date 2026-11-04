#!/bin/sh
# Runs k3s (a single-node Kubernetes cluster) on the NAS, as root, with its data in the persistent path Nas_Prog/_k3s -
# kept across reinstalls. Run by the app's scripts and its management page:
#   k3s_ctl.sh setup      - the kernel modules and settings Kubernetes needs, its folders and settings (every start)
#   k3s_ctl.sh start      - set up, then start k3s (its API on port 6443)
#   k3s_ctl.sh stop       - stop k3s and everything it runs: its pods, their mounts, network and firewall rules
#   k3s_ctl.sh restart    - restart k3s itself (the pods keep running), without waiting for it to be ready
#   k3s_ctl.sh kubeconfig - print a kubeconfig for other computers (the NAS's address instead of 127.0.0.1)
#   k3s_ctl.sh daily      - the daily job: keeping its log small
#   k3s_ctl.sh reset      - stop, then delete the whole cluster (everything in it: workloads, volumes, images)
#
# WD's kernel (4.14, cgroup v1 only) lacks some of what Kubernetes needs: the app brings those as kernel modules (built
# from WD's GPL source by static/k3s), only loaded on the model and firmware they were built for

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_k3s"
PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:${PATH}"
K3S="${APP_PATH}/binaries/k3s"
MODULES_PATH="${APP_PATH}/modules"
K3S_DATA="${DATA_PATH}/data"
KUBELET_DIR="${DATA_PATH}/kubelet"
STORAGE_PATH="${DATA_PATH}/storage"
POD_LOGS="${DATA_PATH}/pod-logs"
SETTINGS_FILE="${DATA_PATH}/settings"
NODE_FILE="${DATA_PATH}/node_name"
KERNEL_FILE="${DATA_PATH}/kernel"
K3S_LOG="${DATA_PATH}/k3s.log"
KUBECONFIG_FILE=/etc/rancher/k3s/k3s.yaml
PID_FILE=/var/run/k3s.pid
LOG=/tmp/debug_apkg

# WD's own kernel modules Kubernetes needs (as Docker does), loaded in this order if they aren't already
WD_DRIVERS='exportfs nf_conntrack nf_nat nf_defrag_ipv4 nf_conntrack_ipv4 nf_nat_ipv4 x_tables xt_conntrack
    xt_addrtype xt_tcpudp xt_nat nf_nat_masquerade_ipv4 ipt_MASQUERADE ip_tables iptable_filter iptable_nat llc stp
    bridge br_netfilter'

# The app's own modules, in loading order: overlay (containerd's overlayfs snapshotter), and the iptables matches,
# targets and table kube-proxy and flannel use
APP_MODULES='overlay xt_comment xt_multiport xt_statistic xt_mark nf_reject_ipv4 ipt_REJECT iptable_mangle'

# What the kernel must have for kube-proxy's rules: iptables matches, then targets
NEEDED_MATCHES='comment multiport statistic mark conntrack addrtype'
NEEDED_TARGETS='REJECT MARK MASQUERADE DNAT SNAT'

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') k3s/k3s_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. MEMORY)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether k3s is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# Waits for a process to exit.
#
# $1 pid     The process
# $2 seconds The longest to wait
#
# Returns 0 if it exited in time
wait_for_exit() {
    local waited=0

    while kill -0 "$1" 2>/dev/null; do
        if [ "${waited}" -ge "$2" ]; then
            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done

    return 0
}

# Loads one of WD's own kernel modules, unless it's loaded already.
#
# $1 name The module
#
# Prints nothing; returns 0 if it's loaded
load_wd_driver() {
    lsmod | grep -q "^$1 " && return 0
    [ -f "/usr/local/modules/driver/$1.ko" ] || return 1
    insmod "/usr/local/modules/driver/$1.ko" 2>/dev/null
}

# Loads one of the app's own kernel modules, but only on the exact model and firmware it was built for (a module built
# for any other kernel could crash it), and never again after an attempt that never finished (e.g. it crashed the NAS).
#
# $1 name The module
#
# Prints why it isn't loaded; returns 0 if it's loaded
load_app_module() {
    local model firmware module marker

    lsmod | grep -q "^$1 " && return 0
    model="$(cat /usr/local/modules/files/model 2>/dev/null)"
    model="${model#WD}"
    firmware="$(cat /etc/version 2>/dev/null)"
    module="${MODULES_PATH}/${model}/$1.ko"

    if [ ! -f "${module}" ]; then
        echo "$1: no module built for this NAS (${model:-unknown model})"

        return 1
    fi

    if [ "${firmware}" != "$(cat "${MODULES_PATH}/firmware" 2>/dev/null)" ]; then
        echo "$1: built for firmware $(cat "${MODULES_PATH}/firmware" 2>/dev/null), but this is ${firmware}"

        return 1
    fi

    # A marker that only survives if loading crashed the NAS, so that it isn't tried again on the next start (e.g. boot)
    marker="${DATA_PATH}/.loading-$1"

    if [ -f "${marker}" ]; then
        echo "$1: an earlier attempt never finished (the NAS may have crashed) - delete ${marker} to try again"

        return 1
    fi

    touch "${marker}" && sync

    if ! insmod "${module}" 2>/dev/null; then
        rm -f "${marker}"
        echo "$1: failed to load"

        return 1
    fi

    rm -f "${marker}"
    log "loaded kernel module: $1 (built for ${model}, firmware ${firmware})"
}

# Loads the kernel modules, then writes what the kernel still lacks to the kernel file (for the management page): one
# "module <why>" or "missing <feature>" line each, empty when nothing's missing. Only on WD's NAS (its model file): other
# kernels (e.g. the tests') load what iptables needs by themselves, when it's first used.
#
# Prints nothing
prepare_kernel() {
    local driver module why match target missing=''

    : > "${KERNEL_FILE}"
    [ -f /usr/local/modules/files/model ] || return 0

    # IPv6 (WD loads it with IPv6 itself switched off, as Docker's app does): ip6tables needs it
    if ! lsmod | grep -q '^ipv6 ' && [ -f /usr/local/modules/driver/ipv6.ko ]; then
        insmod /usr/local/modules/driver/ipv6.ko disable_ipv6=1 2>/dev/null
    fi

    for driver in ${WD_DRIVERS}; do
        load_wd_driver "${driver}"
    done

    for module in ${APP_MODULES}; do
        why="$(load_app_module "${module}")" || missing="${missing}module ${why}
"
    done

    # Anything the kernel has built in (or as a module now loaded) is registered with iptables
    for match in ${NEEDED_MATCHES}; do
        grep -qx "${match}" /proc/net/ip_tables_matches 2>/dev/null || missing="${missing}missing iptables match: ${match}
"
    done

    for target in ${NEEDED_TARGETS}; do
        grep -qx "${target}" /proc/net/ip_tables_targets 2>/dev/null || missing="${missing}missing iptables target: ${target}
"
    done

    printf '%s' "${missing}" > "${KERNEL_FILE}"

    if [ -n "${missing}" ]; then
        log "the kernel lacks what Kubernetes needs - k3s may not work: $(echo ${missing})"
    fi
}

# The name of the cluster's node: the NAS's name, as Kubernetes allows it (lower case letters, digits and -), chosen
# once (a node renamed later would be a new node).
#
# Prints the name
node_name() {
    local name

    if [ ! -s "${NODE_FILE}" ]; then
        name="$(hostname | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-' | sed 's/^-*//; s/-*$//' | cut -c 1-63)"
        echo "${name:-nas}" > "${NODE_FILE}"
    fi

    cat "${NODE_FILE}"
}

# The NAS's address on the local network.
#
# Prints it, or nothing
nas_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1
}

# The memory the NAS keeps for itself (and its other apps) - what isn't the cluster's share of it, chosen on the
# management page (a quarter to 90%; half by default, a third on devices with 1GB or less).
#
# Prints it in MiB
reserved_memory_mb() {
    local total_kb percent

    total_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
    percent="$(setting MEMORY '')"

    case "${percent}" in
        2[5-9]|[3-8][0-9]|90) ;;
        *)
            percent=50
            [ "${total_kb}" -gt 1048576 ] || percent=33
            ;;
    esac

    echo $((total_kb * (100 - percent) / 100 / 1024))
}

# Mounts what Kubernetes expects of a Linux system that WD's lacks.
#
# Prints nothing
prepare_system() {
    # cgroups (WD mounts them; the Docker app remounts them its own way, which is as good)
    if ! awk '$2 == "/sys/fs/cgroup/memory" { found = 1 } END { exit !found }' /proc/self/mounts \
        && ! awk '$1 == "cgroup2" && $2 == "/sys/fs/cgroup" { found = 1 } END { exit !found }' /proc/self/mounts \
        && [ -x /usr/sbin/cgroupfs-mount ]; then
        /usr/sbin/cgroupfs-mount
    fi

    # Volumes shared between a pod and the NAS (mount propagation), and the kernel log the kubelet watches for OOM kills
    mount --make-rshared / 2>/dev/null
    [ -e /dev/kmsg ] || mknod /dev/kmsg c 1 11

    # Pods route through the NAS, and their bridge's traffic goes through iptables
    echo 1 > /proc/sys/net/ipv4/ip_forward

    if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
        echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
    else
        log 'WARNING: no br_netfilter - pods will not reach services whose pods share their bridge (e.g. CoreDNS)'
    fi

    # The pods' logs are kept with the cluster, not in the NAS's small /var/log (in RAM)
    mkdir -p "${POD_LOGS}" /var/log

    if [ "$(readlink /var/log/pods)" != "${POD_LOGS}" ]; then
        rm -rf /var/log/pods
        ln -s "${POD_LOGS}" /var/log/pods
    fi

    # A stable machine ID (the NAS's /etc is in RAM)
    if [ ! -s /etc/machine-id ]; then
        [ -s "${DATA_PATH}/machine-id" ] \
            || tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > "${DATA_PATH}/machine-id"
        cp "${DATA_PATH}/machine-id" /etc/machine-id
    fi
}

# Writes the kubelet's settings k3s's options don't cover (a drop-in in its configuration folder): WD's kernel only has
# cgroup v1 (which Kubernetes refuses by default since 1.35), the NAS has swap, and the memory the pods may use.
#
# Prints nothing
write_kubelet_config() {
    local folder="${K3S_DATA}/agent/etc/kubelet.conf.d"

    mkdir -p "${folder}"
    cat > "${folder}/50-wd-nas.conf" <<EOF
# Written by the k3s app at every start: changes here are overwritten
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failCgroupV1: false
failSwapOn: false
systemReserved:
  memory: $(reserved_memory_mb)Mi
EOF
}

setup() {
    mkdir -p "${DATA_PATH}" "${K3S_DATA}" "${KUBELET_DIR}" "${STORAGE_PATH}"
    chmod 700 "${DATA_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'MEMORY=\nSERVICELB=0\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${K3S_LOG}"
    chmod 600 "${K3S_LOG}"

    # Every k3s command (kubectl and crictl too, from the shell or the page) unpacks k3s's tools into its data folder:
    # the cluster's, not /var/lib/rancher (in RAM on the NAS). k3s reads it from its configuration file (/etc is in RAM,
    # so this is redone at every boot)
    mkdir -p /etc/rancher/k3s
    printf '# Written by the k3s app: every k3s command uses the cluster'"'"'s data folder\ndata-dir: "%s"\n' "${K3S_DATA}" \
        > /etc/rancher/k3s/config.yaml

    # The node's password (k3s's own, /etc/rancher/node) is kept with the cluster: a new one after a reboot would make
    # the node a stranger to it
    mkdir -p "${DATA_PATH}/node"

    if [ "$(readlink /etc/rancher/node)" != "${DATA_PATH}/node" ]; then
        rm -rf /etc/rancher/node
        ln -s "${DATA_PATH}/node" /etc/rancher/node
    fi

    prepare_kernel
    prepare_system
}

start() {
    local snapshotter=native ip disable_lb='' waited=0

    if running; then
        log "k3s is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    write_kubelet_config

    # Images are layered with overlayfs when the kernel has it (the app's module), else copied whole (slower, much bigger)
    grep -q 'overlay$' /proc/filesystems && snapshotter=overlayfs
    log "containerd snapshotter: ${snapshotter}"
    ip="$(nas_ip)"
    [ "$(setting SERVICELB 0)" = 1 ] || disable_lb='--disable=servicelb'

    # Flannel's host-gw backend (one node: plain routes, no VXLAN - which WD's kernel lacks), no network policies (they
    # need ipset), no Traefik (the Nginx app does HTTPS), and k3s's own iptables (the NAS's lacks the extensions)
    log "starting k3s (log: ${K3S_LOG})"
    "${K3S}" server \
        --data-dir "${K3S_DATA}" \
        --node-name "$(node_name)" \
        ${ip:+--tls-san "${ip}"} \
        --tls-san "$(hostname)" \
        --write-kubeconfig "${KUBECONFIG_FILE}" \
        --write-kubeconfig-mode 600 \
        --flannel-backend host-gw \
        --disable-network-policy \
        --disable traefik \
        ${disable_lb} \
        --default-local-storage-path "${STORAGE_PATH}" \
        --prefer-bundled-bin \
        --snapshotter "${snapshotter}" \
        --kubelet-arg "root-dir=${KUBELET_DIR}" \
        >> "${K3S_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "k3s started with PID: $(cat ${PID_FILE})"

    # It's ready once its kubeconfig is written and its API answers (the node takes a little longer)
    until [ -f "${KUBECONFIG_FILE}" ] && "${K3S}" kubectl get --raw /readyz > /dev/null 2>&1; do
        if ! running; then
            log "k3s exited during startup, see: ${K3S_LOG}"

            return 1
        fi

        if [ "${waited}" -ge "${START_WAIT:-120}" ]; then
            log "k3s's API isn't answering yet (it may still be starting), see: ${K3S_LOG}"

            return 0
        fi

        sleep 2
        waited=$((waited + 2))
    done

    log 'k3s is ready'
}

# Stops k3s itself (the pods keep running, as when k3s is updated).
#
# Prints what it did
stop_server() {
    local pid

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping k3s (PID ${pid})"
        kill "${pid}"

        if ! wait_for_exit "${pid}" 60; then
            log 'k3s did not stop within 60 seconds, killing it'
            kill -9 "${pid}" 2>/dev/null
            wait_for_exit "${pid}" 5
        fi
    fi

    rm -f "${PID_FILE}"
}

# The processes descended from one (its children, theirs...).
#
# $1 pid The process
#
# Prints their PIDs, one a line
descendants() {
    local child

    for child in $(awk -v parent="$1" '$4 == parent { print $1 }' /proc/[0-9]*/stat 2>/dev/null); do
        echo "${child}"
        descendants "${child}"
    done
}

# Stops k3s and everything it started (as k3s's own k3s-killall.sh does): the pods' containers and their shims, their
# mounts, the network interfaces and the firewall rules - leaving the rules of others (e.g. Docker's) in place.
#
# Prints what it did
stop() {
    local exe pid shims='' bin

    stop_server

    # The containers' shims (k3s's own containerd-shim, from its data folder) and everything they run
    for exe in /proc/[0-9]*/exe; do
        case "$(readlink "${exe}" 2>/dev/null)" in
            "${K3S_DATA}"/data/*/bin/containerd-shim*)
                pid="${exe#/proc/}"
                shims="${shims} ${pid%/exe}"
                ;;
        esac
    done

    if [ -n "${shims}" ]; then
        log 'stopping the pods'

        for pid in ${shims}; do
            kill -9 $(descendants "${pid}") "${pid}" 2>/dev/null
        done

        sleep 1
    fi

    # The mounts of containerd, the kubelet and the pods' network namespaces (deepest first)
    awk '{ print $2 }' /proc/self/mounts \
        | grep -E "^(/run/k3s|${KUBELET_DIR}|${K3S_DATA}|/run/netns/cni-)" \
        | sort -r \
        | while read -r mount; do
            umount "${mount}" 2>/dev/null || umount -l "${mount}" 2>/dev/null
        done
    rm -rf /run/k3s /run/flannel /run/netns/cni-* 2>/dev/null

    # The pods' network: their bridge, and Kubernetes' and flannel's firewall rules (with k3s's own iptables, which
    # understands them)
    ip link delete cni0 2>/dev/null
    ip link delete flannel.1 2>/dev/null
    bin="${K3S_DATA}/data/current/bin"

    if [ -x "${bin}/aux/iptables-save" ]; then
        bin="${bin}/aux"
    fi

    if [ -x "${bin}/iptables-save" ]; then
        "${bin}/iptables-save" | grep -v 'KUBE-\|CNI-\|flannel\|FLANNEL' | "${bin}/iptables-restore"
    fi
}

# Prints a kubeconfig for other computers: k3s's own, with the NAS's address in place of 127.0.0.1.
#
# Prints it; returns 1 if k3s hasn't written one yet
kubeconfig() {
    local ip

    [ -f "${KUBECONFIG_FILE}" ] || return 1
    ip="$(nas_ip)"
    sed -e "s#https://127.0.0.1:6443#https://${ip:-127.0.0.1}:6443#" \
        -e "s#: default\$#: $(node_name)#" "${KUBECONFIG_FILE}"
}

# Keeps k3s's log under 5MB (the previous part is kept as k3s.log.1).
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${K3S_LOG}" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        cp "${K3S_LOG}" "${K3S_LOG}.1" && : > "${K3S_LOG}"
        chmod 600 "${K3S_LOG}.1"
    fi
}

# Deletes the whole cluster (stopped first): its workloads, volumes and images. The settings are kept.
#
# Prints what it did
reset() {
    stop
    log "deleting the cluster: ${K3S_DATA} ${KUBELET_DIR} ${STORAGE_PATH} ${POD_LOGS}"
    rm -rf "${K3S_DATA}" "${KUBELET_DIR}" "${STORAGE_PATH}" "${POD_LOGS}" "${KUBECONFIG_FILE}"
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart)
        # For the management page, which can't wait long: only long enough to see it didn't fail straight away
        stop_server
        START_WAIT=10 start
        ;;
    kubeconfig) kubeconfig ;;
    daily) rotate_log ;;
    reset) reset ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|kubeconfig|daily|reset" >&2

        exit 1
        ;;
esac
