#!/bin/sh
# Runs copyparty (file sharing in the browser) as its own user, with its data in the persistent path (Nas_Prog/_copyparty
# - kept across reinstalls):
#   cpp_ctl.sh setup                - create its user, folders and default settings (where missing)
#   cpp_ctl.sh start                - write its configuration from the settings, then start it (on port 3923: the network,
#                                     or the NAS itself only)
#   cpp_ctl.sh stop                 - stop copyparty
#   cpp_ctl.sh restart              - stop, then start
#   cpp_ctl.sh check-folder <path>  - whether copyparty's user can read and write a folder (exit status 0: both, 1:
#                                     read only, 2: neither)
#   cpp_ctl.sh daily                - the daily job: keeping its log small
#   cpp_ctl.sh nginx                - add / update copyparty's site in the Nginx app (and reload it)
#
# Its user's group is the NAS's share group (which every NAS user is in, and which owns what's copied over SMB): files it
# creates in the shares are writable by that group, so they can be changed over SMB too, and the other way round

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_copyparty"
# (PHP finds the Nginx app's address: wherever it is, also when run with a minimal PATH, e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
CONFIG_DIR="${DATA_PATH}/config"
CPP_LOG="${DATA_PATH}/copyparty.log"
PID_FILE=/var/run/copyparty.pid
PORT=3923
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
CPP_ID=81
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') copyparty/cpp_ctl.sh $*" >> ${LOG}
	echo "$*"
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
cpp_ids() {
	awk -F: '$1 == "copyparty" { print $3 " " $4 }' /etc/passwd
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
	# group, on a NAS without one
	if ! grep -q '^copyparty:' /etc/passwd; then
		group=share
		if ! grep -q '^share:' /etc/group; then
			group=copyparty
			grep -q '^copyparty:' /etc/group || addgroup -g ${CPP_ID} copyparty
		fi
		adduser -D -H -h /nonexistent -s /bin/false -u ${CPP_ID} -G ${group} copyparty
	fi
	if [ -z "$(cpp_ids)" ]; then
		log "Could not create the copyparty user (is ID ${CPP_ID} already taken?)"
		return 1
	fi
	set -- $(cpp_ids)

	# Its data (configuration, sessions, database and thumbnails) belongs to its user; the settings (with the users'
	# passwords) and the password salt to root
	mkdir -p "${CONFIG_DIR}" "${DATA_PATH}/hist"
	chmod 711 "${DATA_PATH}"
	chown -R "$1:$2" "${CONFIG_DIR}" "${DATA_PATH}/hist"
	chmod 700 "${CONFIG_DIR}" "${DATA_PATH}/hist"
	"${PYTHON}" -I "${APP_PATH}/lib/cpp_conf.py" default "${DATA_PATH}" || return 1
	touch "${CPP_LOG}"
	chmod 600 "${CPP_LOG}"
}

write_config() {
	set -- $(cpp_ids)
	"${PYTHON}" -I "${APP_PATH}/lib/cpp_conf.py" write "${DATA_PATH}" "${APP_PATH}" || return 1
	chown "$1:$2" "${CONFIG_DIR}/copyparty.conf"
	[ ! -d "${DATA_PATH}/empty" ] || chown "$1:$2" "${DATA_PATH}/empty"
}

# Waits up to 60 seconds for copyparty to answer
wait_up() {
	waited=0
	while [ ${waited} -lt 60 ]; do
		curl -s -o /dev/null "http://127.0.0.1:${PORT}/" && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start() {
	if running; then
		log "copyparty is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	write_config || return 1
	set -- $(cpp_ids)
	log "starting copyparty on port ${PORT} (log: ${CPP_LOG})"
	# (its configuration folder: sessions, the SFTP server's keys, its own salts. ffmpeg and ffprobe from the app. Its log
	# is appended to, so that it can be cut short while it runs)
	cd "${CONFIG_DIR}" || return 1
	( exec env XDG_CONFIG_HOME="${CONFIG_DIR}" PATH="${BIN}:/usr/bin:/bin" LANG=C.UTF-8 \
		"${BIN}/cpp_runas" "$1" "$2" "${PYTHON}" -m copyparty -c "${CONFIG_DIR}/copyparty.conf" ) >> "${CPP_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	log "copyparty started with PID: $(cat ${PID_FILE})"
	wait_up || log "copyparty did not answer within 60 seconds (see ${CPP_LOG})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping copyparty (PID ${pid})"
		kill "${pid}"
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 20 ]; then
				log "copyparty did not stop within 20 seconds, killing it"
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "${PID_FILE}"
}

# Whether copyparty's user can read (and list) a folder, and write to it
check_folder() {
	set -- $(cpp_ids) "$1"
	[ -d "$3" ] && "${BIN}/cpp_runas" "$1" "$2" /bin/ls "$3" > /dev/null 2>&1 || return 2
	"${BIN}/cpp_runas" "$1" "$2" /bin/sh -c 'test -w "$1" && test -x "$1"' sh "$3" || return 1
}

# Keeps copyparty's log under 5MB (the previous part is kept as copyparty.log.1)
rotate_log() {
	if [ "$(wc -c < "${CPP_LOG}" 2>/dev/null || echo 0)" -gt 5242880 ]; then
		cp "${CPP_LOG}" "${CPP_LOG}.1" && : > "${CPP_LOG}"
		chmod 600 "${CPP_LOG}.1"
	fi
}

# The Nginx app finds copyparty by its folder and serves it at https://files.<its domain>: rewrite its sites
nginx_site() {
	nginx_app="${APPS_PATH}/nginx"
	if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
		php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
	fi
	return 0
}

case "$1" in
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	restart) stop; start ;;
	check-folder) setup > /dev/null && check_folder "$2" ;;
	daily) rotate_log ;;
	nginx) nginx_site ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|check-folder <path>|daily|nginx" >&2
		exit 1
		;;
esac
