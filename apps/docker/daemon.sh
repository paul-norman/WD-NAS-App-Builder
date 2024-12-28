#!/bin/bash

export DOCKER_RAMDISK=1

LOG="/tmp/debug_apkg"

DOCKER=/sbin/docker
DOCKERD=/sbin/dockerd

DOCKER_ROOT=/shares/Volume_1/Nas_Prog/_docker

log() {
	if [ ! -f "${LOG}" ]; then
		touch ${LOG};
	fi
	
	if [ "$1" == "" ]; then
		echo "" >> ${LOG};
	elif [ "$1" == "---" ]; then
		echo "----------------------------------------------------------------" >> ${LOG};
	else
		echo "$(date '+%Y-%m-%d %H:%M:%S') docker/daemon.sh $1" >> ${LOG};
	fi
}

is_mountpoint() {
	mnts=$(cat /proc/self/mounts | grep "$1" | awk '{print $2}')

	for i in "${mnts[@]}"
	do
		if [ "$i" == "$1" ] ; then
			return 0
		fi
	done

	return 1
}

is_docker_setup() {
	path=$(readlink -f /var/lib/docker)
	btrfs_mounted=$(cat /proc/mounts | grep "${path}")
	if [ -z "${btrfs_mounted}" ]; then
		log "Docker is not yet setup"
		return 1
	else 
		log "Docker is setup"
	fi
}

docker_setup() {
	is_docker_setup && return 0

	log "Setting up docker"

	# Ensure that we have a Docker directory
	if [ -L /var/lib/docker ]; then
		log "Found Docker symlink"
	else
		log "No Docker symlink found, creating..."
		ln -sf ${DOCKER_ROOT} /var/lib/docker 
	fi

	# For iptables
	ln -s /usr/local/modules/usrlib/xtables /usr/lib/xtables

	if [ ! -L /usr/sbin/mkfs.ext4 ]; then
		ln -s /usr/bin/mke2fs /usr/sbin/mkfs.ext4
	fi

	if ! $(lsmod | grep ^ipv6 &> /dev/null); then
		log "Loading ipv6"
		insmod /usr/local/modules/driver/ipv6.ko disable_ipv6=1
	fi

	log "Loading drivers"

	drivers=(
		"nf_conntrack"
		"nf_nat"
		"nf_defrag_ipv4"
		"nf_conntrack_ipv4"
		"nf_nat_ipv4"
		"x_tables"
		"xt_conntrack"
		"xt_addrtype"
		"xt_tcpudp"
		"xt_nat"
		"nf_nat_masquerade_ipv4"
		"ipt_MASQUERADE"
		"ip_tables"
		"iptable_filter"
		"iptable_nat"
		"llc"
		"stp"
		"bridge"
		"br_netfilter"
	)

	for driver in "${drivers[@]}"; do
		if ! $(lsmod | grep -w ${driver} &> /dev/null); then
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

docker_stop() {
	# Stop all containers
	containers="$(${DOCKER} ps -q)"
	if [ ! -z "${containers}" ]; then
		log "Stopping containers ${containers}"
		${DOCKER} stop ${containers}
	fi

	# Stop docker
	docker_pid="$(cat /var/run/docker.pid)"
	if [ ! -z "${docker_pid}" ]; then
		log "Stopping Docker pid=${docker_pid}"
		kill "${docker_pid}"
	fi
}

dm_cleanup() {
	shm_mounts=$(cat /proc/self/mounts | grep "shm.*docker" | awk '{print $2}')
	
	for mnt in "${shm_mounts[@]}"; do
		log "shm_cleanup: ${mnt}"
		umount "$mnt"
	done 
	
	if [ ! -z $(cat /proc/self/mounts | grep -c docker) ]; then
		path=$(readlink -f /var/lib/docker)
		umount ${path}/plugins
		umount ${path}
	fi
	
	dmsetup remove_all
}

docker_cleanup() {
	log "Cleaning up Docker"

	# Remove cgroup stuff
	/usr/sbin/cgroupfs-umount

	dm_cleanup
}

set_docker_cgroup() {
	ONE_G_KB=1048576

	mem_quota=0
	mem_total_kb=`grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'`

	if [[ ! "${mem_total_kb}" =~ ^[0-9]+$ ]] ; then
		log "Failed to get total memory!"
		return 1
	fi

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
		is_docker_setup || (log "Docker is not setup! Run docker/daemon.sh setup" && exit 1)
		dm_cleanup
		cgroupfs-mount
		set_docker_cgroup
		${DOCKERD} --ip-masq=true >> /var/lib/docker/docker.log 2>&1 &
		docker_pid=$!
		log "Docker pid ${docker_pid}"
		# Attach docker pid to memory cgroup
		if [[ "${docker_pid}" =~ ^[0-9]+$ ]]; then
			log "Attaching Docker pid to memory cgroup"
			echo ${docker_pid} > /sys/fs/cgroup/memory/docker/tasks
		fi
		;;
	stop)
		docker_stop
		;;
	status)
		docker_pid=$(pidof dockerd)
		docker_mounts=$(cat /proc/self/mounts | grep docker)
		if [ -z "${docker_pid}" ]; then
			log "Docker is not running!"
			if [ "${docker_mounts}" ]; then
				log "Found mounts: ${docker_mounts}"
			fi
			exit 1
		else
			log "Docker is running with PID: ${docker_pid}"
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