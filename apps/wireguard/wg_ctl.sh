#!/bin/sh
# Runs WireGuard (a VPN into the home network) with wireguard-go, WireGuard's userspace implementation, with its settings
# in the persistent path (Nas_Prog/_wireguard - kept across reinstalls):
#   wg_ctl.sh setup    - the kernel's TUN device and iptables' extensions, the data folder
#   wg_ctl.sh start    - start the wg0 interface with the NAS's key and the devices switched on, and route the devices'
#                        traffic as set (the NAS only, the home network too, or everything)
#   wg_ctl.sh stop     - stop it, and remove its routing
#   wg_ctl.sh restart  - stop, then start
#   wg_ctl.sh reload   - apply changed devices to the running interface (connections stay up)
#
# It runs as root: making network interfaces and routing needs it. Nothing answers on its UDP port except to devices
# with a key - WireGuard doesn't reply to anything else

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_wireguard"
# (WD's iptables is in /usr/sbin; PHP may also be the PHP app's)
PATH="${PATH}:/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
IFACE=wg0
PID_FILE=/var/run/wireguard-go.pid
# The IP forwarding setting before WireGuard turned it on (restored when it stops, unless Docker needs it)
FORWARD_FILE=/var/run/wireguard.ip_forward
LOG=/tmp/debug_apkg
WG_LOG="${DATA_PATH}/wireguard.log"

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') wireguard/wg_ctl.sh $*" >> ${LOG}
	echo "$*"
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

setup() {
	mkdir -p "${DATA_PATH}"
	chmod 700 "${DATA_PATH}"
	# The kernel's TUN device (WD ships it as a module, as Tailscale uses it)
	if ! grep -q '^tun ' /proc/modules 2>/dev/null && [ -f /usr/local/modules/driver/tun.ko ]; then
		insmod /usr/local/modules/driver/tun.ko 2>/dev/null
	fi
	if [ ! -c /dev/net/tun ]; then
		mkdir -p /dev/net
		mknod /dev/net/tun c 10 200
	fi
	# Routing the devices' traffic: WD's netfilter modules (as the Docker app loads them) and iptables' extensions
	for module in x_tables ip_tables iptable_filter nf_conntrack nf_defrag_ipv4 nf_conntrack_ipv4 nf_nat nf_nat_ipv4 \
		iptable_nat xt_conntrack xt_tcpudp nf_nat_masquerade_ipv4 ipt_MASQUERADE; do
		if ! grep -q "^${module} " /proc/modules 2>/dev/null && [ -f "/usr/local/modules/driver/${module}.ko" ]; then
			insmod "/usr/local/modules/driver/${module}.ko" 2>/dev/null
		fi
	done
	if [ ! -e /usr/lib/xtables ] && [ -d /usr/local/modules/usrlib/xtables ]; then
		ln -s /usr/local/modules/usrlib/xtables /usr/lib/xtables
	fi
	touch "${WG_LOG}"
	chmod 600 "${WG_LOG}"
}

# The routing rules, in WireGuard's own chains (so that they're removed in one go, and never mixed up with Docker's)
routing_on() {
	if ! command -v iptables > /dev/null; then
		log "iptables not found: devices can only reach the NAS itself"
		return 0
	fi
	routing_off
	iptables -N WIREGUARD 2>/dev/null
	iptables -I FORWARD 1 -j WIREGUARD
	iptables -t nat -N WIREGUARD 2>/dev/null
	iptables -t nat -I POSTROUTING 1 -j WIREGUARD
	case "${WG_ACCESS}" in
		lan)
			[ -n "${LAN_SUBNET}" ] && iptables -A WIREGUARD -i ${IFACE} -d "${LAN_SUBNET}" -j ACCEPT
			;;
		all)
			iptables -A WIREGUARD -i ${IFACE} -j ACCEPT
			;;
	esac
	if [ "${WG_ACCESS}" != nas ]; then
		iptables -A WIREGUARD -o ${IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
		# (the home network sees the NAS's address, so its devices need no route back)
		[ -n "${LAN_DEVICE}" ] && iptables -t nat -A WIREGUARD -s "${WG_SUBNET}" -o "${LAN_DEVICE}" -j MASQUERADE
		# Forwarding on (remembering how it was)
		[ -f "${FORWARD_FILE}" ] || cat /proc/sys/net/ipv4/ip_forward > "${FORWARD_FILE}"
		echo 1 > /proc/sys/net/ipv4/ip_forward
	fi
	iptables -A WIREGUARD -i ${IFACE} -j DROP
	return 0
}

routing_off() {
	command -v iptables > /dev/null || return 0
	while iptables -D FORWARD -j WIREGUARD 2>/dev/null; do :; done
	iptables -F WIREGUARD 2>/dev/null && iptables -X WIREGUARD 2>/dev/null
	while iptables -t nat -D POSTROUTING -j WIREGUARD 2>/dev/null; do :; done
	iptables -t nat -F WIREGUARD 2>/dev/null && iptables -t nat -X WIREGUARD 2>/dev/null
	# Forwarding back as it was, unless Docker (which needs it) is running
	if [ -f "${FORWARD_FILE}" ]; then
		pidof dockerd > /dev/null || cat "${FORWARD_FILE}" > /proc/sys/net/ipv4/ip_forward
		rm -f "${FORWARD_FILE}"
	fi
	return 0
}

load_env() {
	env="$(php "${APP_PATH}/lib/wg.php" env "${DATA_PATH}")" || return 1
	eval "${env}"
}

# The interface's keys and devices (wg setconf reads them from a file: through a root-only one, briefly)
apply_conf() {
	conf="${DATA_PATH}/.setconf"
	( umask 077; php "${APP_PATH}/lib/wg.php" setconf "${DATA_PATH}" "${APP_PATH}" > "${conf}" ) || return 1
	"${BIN}/wg" setconf ${IFACE} "${conf}"
	result=$?
	rm -f "${conf}"
	return ${result}
}

start() {
	if running; then
		log "WireGuard is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup
	load_env || { log "WireGuard's settings could not be read"; return 1; }
	log "starting WireGuard (${IFACE}, UDP port ${WG_PORT}, ${WG_ADDRESS}, access: ${WG_ACCESS})"
	( exec env WG_PROCESS_FOREGROUND=1 LOG_LEVEL=error "${BIN}/wireguard-go" ${IFACE} ) >> "${WG_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	# (its control socket appears once the interface exists)
	waited=0
	while [ ! -S /var/run/wireguard/${IFACE}.sock ]; do
		if [ ${waited} -ge 20 ] || ! running; then
			log "WireGuard did not start (see ${WG_LOG})"
			stop
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	if ! apply_conf; then
		log "WireGuard's configuration could not be applied"
		stop
		return 1
	fi
	if ! ip address add "${WG_ADDRESS}" dev ${IFACE} || ! ip link set dev ${IFACE} mtu 1420 up; then
		log "WireGuard's interface could not be given its address (${WG_ADDRESS})"
		stop
		return 1
	fi
	if [ -z "${LAN_DEVICE}" ] && [ "${WG_ACCESS}" != nas ]; then
		log "The home network wasn't found (no default route): devices can only reach the NAS itself"
	fi
	routing_on
	log "WireGuard started with PID: $(cat ${PID_FILE})"
}

stop() {
	routing_off
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping WireGuard (PID ${pid})"
		kill "${pid}"
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 10 ]; then
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "${PID_FILE}"
}

case "$1" in
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	restart) stop; start ;;
	reload) running && apply_conf ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|reload" >&2
		exit 1
		;;
esac
