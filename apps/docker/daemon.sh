#!/bin/sh

export DOCKER_RAMDISK=1

# The app's binaries (which dockerd looks for in the PATH) are linked into /sbin
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:${PATH}"

LOG='/tmp/debug_apkg'

DOCKER=/sbin/docker
DOCKERD=/sbin/dockerd
DOCKER_PID_FILE=/var/run/docker.pid

# Persistent data lives next to the app (e.g. /mnt/HD/HD_a2/Nas_Prog/_docker), whichever volume it is installed on
APP_PATH="$(dirname "$(readlink -f "$0")")"
DOCKER_ROOT="$(dirname "${APP_PATH}")/_docker"
DOCKER_LOG="${DOCKER_ROOT}/docker.log"

DOCKER_CONFIG_FILE="${APP_PATH}/daemon.json"

# Kernel modules that WD's kernel lacks (overlay, iptable_raw), built from WD's GPL source by static/docker for one
# firmware version: modules/<model>/*.ko, plus a "firmware" file saying which version
MODULES_PATH="${APP_PATH}/modules"

log() {
    if [ ! -f "${LOG}" ]; then
        touch ${LOG}
    fi

    if [ "$1" = '' ]; then
        echo '' >> ${LOG}
    elif [ "$1" = '---' ]; then
        echo '----------------------------------------------------------------' >> ${LOG}
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') docker/daemon.sh $1" >> ${LOG}
    fi
}

is_mountpoint() {
    awk -v mnt="$1" '$2 == mnt { found = 1 } END { exit !found }' /proc/self/mounts
}

is_docker_setup() {
    if [ "$(readlink /var/lib/docker)" = "${DOCKER_ROOT}" ] && is_mountpoint /sys/fs/cgroup/memory; then
        log 'Docker is setup'

        return 0
    fi

    log 'Docker is not yet setup'

    return 1
}

# Loads one of the app's own kernel modules, but only on the exact model and firmware it was built for: a module built
# for any other kernel could crash it
load_app_module() {
    if lsmod | grep -q "^$1 "; then
        return 0
    fi

    model="$(cat /usr/local/modules/files/model 2>/dev/null)"
    model="${model#WD}"
    firmware="$(cat /etc/version 2>/dev/null)"
    module="${MODULES_PATH}/${model}/$1.ko"

    if [ ! -f "${module}" ]; then
        log "Not loading $1: no module built for ${model}"

        return 1
    fi

    if [ "${firmware}" != "$(cat ${MODULES_PATH}/firmware)" ]; then
        log "Not loading $1: built for firmware $(cat ${MODULES_PATH}/firmware), but this is firmware ${firmware} (rebuild the app for it)"

        return 1
    fi

    # A marker that only survives if loading crashed the NAS, so that it isn't tried again on the next start (e.g. boot)
    marker="${DOCKER_ROOT}/.loading-$1"

    if [ -f "${marker}" ]; then
        log "Not loading $1: a previous attempt never finished (the NAS may have crashed). Delete ${marker} to try again"

        return 1
    fi

    log "Loading: $1 (built for ${model} firmware ${firmware})"
    touch "${marker}" && sync

    if ! insmod "${module}"; then
        log " - failed to load $1"
        rm -f "${marker}"

        return 1
    fi
    rm -f "${marker}"
}

# Prints the PID of the running Docker daemon (if any)
docker_pid() {
    pid="$(cat ${DOCKER_PID_FILE} 2>/dev/null)"

    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "${pid}"
    else
        pidof dockerd
    fi
}

# Waits up to $2 seconds for process $1 to exit
wait_for_exit() {
    waited=0

    while kill -0 "$1" 2>/dev/null; do
        if [ ${waited} -ge $2 ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 0
}

docker_setup() {
    is_docker_setup && return 0

    log 'Setting up docker'

    # Ensure that we have a Docker directory
    mkdir -p "${DOCKER_ROOT}"

    if [ "$(readlink /var/lib/docker)" = "${DOCKER_ROOT}" ]; then
        log 'Found Docker symlink'
    else
        log "Creating Docker symlink: /var/lib/docker -> ${DOCKER_ROOT}"
        rm -f /var/lib/docker
        ln -sf "${DOCKER_ROOT}" /var/lib/docker
    fi

    # For iptables
    if [ ! -e /usr/lib/xtables ]; then
        ln -s /usr/local/modules/usrlib/xtables /usr/lib/xtables
    fi

    if [ ! -L /usr/sbin/mkfs.ext4 ]; then
        ln -s /usr/bin/mke2fs /usr/sbin/mkfs.ext4
    fi

    if ! lsmod | grep -q '^ipv6 '; then
        log 'Loading ipv6'
        insmod /usr/local/modules/driver/ipv6.ko disable_ipv6=1
    fi

    log 'Loading drivers'

    drivers="
		exportfs
		nf_conntrack
		nf_nat
		nf_defrag_ipv4
		nf_conntrack_ipv4
		nf_nat_ipv4
		x_tables
		xt_conntrack
		xt_addrtype
		xt_tcpudp
		xt_nat
		nf_nat_masquerade_ipv4
		ipt_MASQUERADE
		ip_tables
		iptable_filter
		iptable_nat
		llc
		stp
		bridge
		br_netfilter
	"

    for driver in ${drivers}; do
        if ! lsmod | grep -qw "^${driver}"; then
            log "Loading: ${driver}"

            if ! insmod "/usr/local/modules/driver/${driver}.ko" ; then
                log " - failed to load ${driver}"
            fi
        else
            log "${driver} already loaded"
        fi
    done

    # The app's own modules: overlay (for containerd's overlayfs image storage) and iptable_raw (see docker_start)
    load_app_module overlay
    load_app_module iptable_raw

    log 'Setting up cgroup'
    umount /sys/fs/cgroup 2>/dev/null
    /usr/sbin/cgroupfs-mount

    # On Yosemite /dev/pts is not mounted; required for Docker container tty
    if [ ! -d /dev/pts ]; then
        mkdir /dev/pts
        mount -t devpts devpts /dev/pts
    fi
}

docker_start() {
    pid="$(docker_pid)"

    if [ -n "${pid}" ]; then
        log "Docker is already running with PID: ${pid}"

        return 0
    fi

    if ! is_docker_setup; then
        log "Docker is not setup! Run docker/daemon.sh setup"

        return 1
    fi

    # Clear any mounts left behind by a previous Docker that didn't shut down cleanly
    dm_cleanup
    set_docker_cgroup

    # Docker 28+ uses the iptables "raw" table to stop other machines reaching container ports that aren't published.
    # Without it (no iptable_raw module) containers can't start at all, so fall back to running without those rules
    if ! iptables -t raw -L -n > /dev/null 2>&1; then
        log 'WARNING: no iptables raw table (iptable_raw module), so Docker runs without its direct access filtering'
        export DOCKER_INSECURE_NO_IPTABLES_RAW=1
    fi

    # Images are stored by containerd (daemon.json turns its image store on: Docker would otherwise keep the older one on
    # a NAS that already used it). It lays them out with overlay when the overlay module is loaded, otherwise with
    # "native" (works everywhere, but every image layer is a full copy). Unlike Docker's older store, containerd skips
    # file attributes that WD's ext4 can't store (security.capability), rather than failing to pull such images
    if grep -q "overlay$" /proc/filesystems; then
        log 'Image storage: containerd with overlayfs'
    else
        log 'Image storage: containerd with native (no overlay module: every image layer is a full copy)'
    fi

    # Images and containers from Docker's older image store (overlay2 or vfs) stay on disk, but are no longer used
    for old in overlay2 vfs; do
        if [ -d "${DOCKER_ROOT}/${old}" ]; then
            log "Note: images and containers from Docker's older ${old} store aren't used any more: pull or create them again, then delete ${DOCKER_ROOT}/${old} and ${DOCKER_ROOT}/image/${old} to free their space"
        fi
    done

    # Join the memory cgroup before starting the daemon, so that containerd and all containers are limited too
    log "Starting dockerd (log: ${DOCKER_LOG})"
    sh -c 'echo $$ > /sys/fs/cgroup/memory/docker/tasks 2>/dev/null; exec "$0" --ip-masq=true --config-file "$1"' "${DOCKERD}" "${DOCKER_CONFIG_FILE}" >> "${DOCKER_LOG}" 2>&1 &
    pid=$!

    # Wait for the daemon to accept commands
    waited=0

    until ${DOCKER} info > /dev/null 2>&1; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "Docker exited during startup, see: ${DOCKER_LOG}"

            return 1
        fi

        if [ ${waited} -ge 60 ]; then
            log "Docker did not become ready within 60 seconds, see: ${DOCKER_LOG}"

            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log "Docker is running with PID: ${pid}"
}

docker_stop() {
    # Stop docker, which stops its containers itself (each within its own stop timeout), and wait for it (and the
    # containerd it manages) to exit before anything is unmounted. Not "docker stop": containers stopped that way count
    # as stopped by the user, so those with "restart: unless-stopped" (e.g. the Store's recipes) wouldn't start again
    pid="$(docker_pid)"

    if [ -n "${pid}" ]; then
        log "Stopping Docker PID: ${pid} (and its containers: $(echo $(${DOCKER} ps -q 2>/dev/null)))"
        kill "${pid}"

        if ! wait_for_exit "${pid}" 90; then
            log 'Docker did not stop within 90 seconds, killing it'
            kill -9 "${pid}" 2>/dev/null
            wait_for_exit "${pid}" 5
        fi
    fi

    for pid in $(pidof containerd); do
        wait_for_exit "${pid}" 10 || kill -9 "${pid}" 2>/dev/null
    done
}

dm_cleanup() {
    grep 'shm.*docker' /proc/self/mounts | awk '{print $2}' | while read -r mnt; do
        log "shm_cleanup: ${mnt}"
        umount "${mnt}"
    done

    # Unmount anything inside the Docker directory (deepest first), then the directory itself
    path="$(readlink -f /var/lib/docker)"

    if [ -n "${path}" ]; then
        awk '{print $2}' /proc/self/mounts | grep "^${path}/" | sort -r | while read -r mnt; do
            log "Unmounting: ${mnt}"
            umount "${mnt}"
        done

        if is_mountpoint "${path}"; then
            log "Unmounting: ${path}"
            umount "${path}"
        fi
    fi
}

docker_cleanup() {
    log 'Cleaning up Docker'

    dm_cleanup

    # Remove cgroup stuff
    /usr/sbin/cgroupfs-umount
}

# The share of the NAS's memory that Docker and all its containers may use, in percent: the one chosen on the management
# page (saved in _docker/memory_limit), otherwise half - a third on devices with 1GB or less
docker_memory_percent() {
    percent="$(cat "${DOCKER_ROOT}/memory_limit" 2>/dev/null)"

    case "${percent}" in
        [1-9][0-9])
            echo "${percent}"

            return
            ;;
    esac

    if [ "$1" -gt 1048576 ]; then
        echo 50
    else
        echo 33
    fi
}

set_docker_cgroup() {
    mem_quota=0
    mem_total_kb=`grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'`

    case "${mem_total_kb}" in
        ''|*[!0-9]*)
            log "Failed to get total memory!"

            return 1
            ;;
    esac

    mem_percent="$(docker_memory_percent "${mem_total_kb}")"
    mem_quota=$((mem_total_kb * mem_percent / 100))

    log "Total RAM: ${mem_total_kb} KB"

    if is_mountpoint /sys/fs/cgroup/memory; then
        log 'Creating /sys/fs/cgroup/memory/docker'
        mkdir -p /sys/fs/cgroup/memory/docker
    else
        log '/sys/fs/cgroup/memory is not a cgroup mount'

        return 1
    fi

    log "Docker quota: ${mem_quota} KB (${mem_percent}%)"

    # Can fail while Docker is running, if its containers already use more than a lower limit and can't give it back
    if ! echo "${mem_quota}K" > /sys/fs/cgroup/memory/docker/memory.limit_in_bytes; then
        log "Could not set the memory quota (in use: $(cat /sys/fs/cgroup/memory/docker/memory.usage_in_bytes) bytes)"

        return 1
    fi
    # Docker and all containers use the same memory limit
    echo 1 > /sys/fs/cgroup/memory/docker/memory.use_hierarchy 2>/dev/null
    log "Set memory quota for docker: $(cat /sys/fs/cgroup/memory/docker/memory.limit_in_bytes)"
}

case $1 in
    start)
        log 'Starting Docker'
        docker_start || exit 1
        ;;
    stop)
        docker_stop
        ;;
    status)
        pid="$(docker_pid)"
        docker_mounts="$(grep docker /proc/self/mounts)"

        if [ -z "${pid}" ]; then
            log "Docker is not running!"

            if [ -n "${docker_mounts}" ]; then
                log "Found mounts: ${docker_mounts}"
            fi

            exit 1
        else
            log "Docker is running with PID: ${pid}"
        fi
        ;;
    setup)
        docker_setup
        ;;
    issetup)
        if ! is_docker_setup ; then
            exit 1
        fi
        ;;
    shutdown)
        docker_stop
        docker_cleanup
        ;;
    memory)
        # Applies the memory limit (e.g. after it was changed on the management page) without restarting Docker
        set_docker_cgroup || exit 1
        ;;
    *)
        log "Invalid command!"

        exit 1
        ;;
esac
