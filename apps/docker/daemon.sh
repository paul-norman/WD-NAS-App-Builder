#!/bin/sh

export DOCKER_RAMDISK=1

# The app's binaries (which dockerd looks for in the PATH) are linked into /sbin
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:${PATH}"

LOG="/tmp/debug_apkg"

DOCKER=/sbin/docker
DOCKERD=/sbin/dockerd
DOCKER_PID_FILE=/var/run/docker.pid

# Persistent data lives next to the app (e.g. /mnt/HD/HD_a2/Nas_Prog/_docker), whichever volume it is installed on
APP_PATH="$(dirname "$(readlink -f "$0")")"
DOCKER_ROOT="$(dirname "${APP_PATH}")/_docker"
DOCKER_LOG="${DOCKER_ROOT}/docker.log"

# The WD kernel (4.14) has no overlay, btrfs or zfs support (and is too old for fuse-overlayfs), so daemon.json selects
# the vfs storage driver
DOCKER_CONFIG_FILE="${APP_PATH}/daemon.json"

log() {
	if [ ! -f "${LOG}" ]; then
		touch ${LOG};
	fi

	if [ "$1" = "" ]; then
		echo "" >> ${LOG};
	elif [ "$1" = "---" ]; then
		echo "----------------------------------------------------------------" >> ${LOG};
	else
		echo "$(date '+%Y-%m-%d %H:%M:%S') docker/daemon.sh $1" >> ${LOG};
	fi
}

is_mountpoint() {
	awk -v mnt="$1" '$2 == mnt { found = 1 } END { exit !found }' /proc/self/mounts
}

is_docker_setup() {
	if [ "$(readlink /var/lib/docker)" = "${DOCKER_ROOT}" ] && is_mountpoint /sys/fs/cgroup/memory; then
		log "Docker is setup"
		return 0
	fi

	log "Docker is not yet setup"
	return 1
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

	log "Setting up docker"

	# Ensure that we have a Docker directory
	mkdir -p "${DOCKER_ROOT}"
	if [ "$(readlink /var/lib/docker)" = "${DOCKER_ROOT}" ]; then
		log "Found Docker symlink"
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

	if ! lsmod | grep -q "^ipv6 "; then
		log "Loading ipv6"
		insmod /usr/local/modules/driver/ipv6.ko disable_ipv6=1
	fi

	log "Loading drivers"

	drivers="
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
		iptable_raw
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

	log "Setting up cgroup"
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
		log "WARNING: no iptables raw table (iptable_raw module), so Docker runs without its direct access filtering"
		export DOCKER_INSECURE_NO_IPTABLES_RAW=1
	fi

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
	# Stop all containers
	containers="$(${DOCKER} ps -q 2>/dev/null)"
	if [ -n "${containers}" ]; then
		log "Stopping containers: $(echo ${containers})"
		${DOCKER} stop ${containers} > /dev/null
	fi

	# Stop docker and wait for it (and the containerd it manages) to exit before anything is unmounted
	pid="$(docker_pid)"
	if [ -n "${pid}" ]; then
		log "Stopping Docker PID: ${pid}"
		kill "${pid}"
		if ! wait_for_exit "${pid}" 30; then
			log "Docker did not stop within 30 seconds, killing it"
			kill -9 "${pid}" 2>/dev/null
			wait_for_exit "${pid}" 5
		fi
	fi

	for pid in $(pidof containerd); do
		wait_for_exit "${pid}" 10 || kill -9 "${pid}" 2>/dev/null
	done
}

dm_cleanup() {
	grep "shm.*docker" /proc/self/mounts | awk '{print $2}' | while read -r mnt; do
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
	log "Cleaning up Docker"

	dm_cleanup

	# Remove cgroup stuff
	/usr/sbin/cgroupfs-umount
}

set_docker_cgroup() {
	ONE_G_KB=1048576

	mem_quota=0
	mem_total_kb=`grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'`

	case "${mem_total_kb}" in
		''|*[!0-9]*)
			log "Failed to get total memory!"
			return 1
			;;
	esac

	if [ ${mem_total_kb} -gt ${ONE_G_KB} ]; then
		mem_quota=$((mem_total_kb/2))
	else
		mem_quota=$((mem_total_kb/3))
	fi

	log "Total RAM: ${mem_total_kb} KB"

	if is_mountpoint /sys/fs/cgroup/memory; then
		log "Creating /sys/fs/cgroup/memory/docker"
		mkdir -p /sys/fs/cgroup/memory/docker
	else
		log "/sys/fs/cgroup/memory is not a cgroup mount"
		return 1
	fi

	log "Docker quota: ${mem_quota} KB"
	if echo "${mem_quota}K" > /sys/fs/cgroup/memory/docker/memory.limit_in_bytes ; then
		# Docker and all containers use the same memory limit
		echo 1 > /sys/fs/cgroup/memory/docker/memory.use_hierarchy
		log "Set memory quota for docker: $(cat /sys/fs/cgroup/memory/docker/memory.limit_in_bytes)"
	fi
}

case $1 in
	start)
		log "Starting Docker"
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
	*)
		log "Invalid command!"
		exit 1
		;;
esac
