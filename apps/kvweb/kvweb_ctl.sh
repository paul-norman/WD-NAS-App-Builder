#!/bin/sh
# Runs kvweb (a web interface for Valkey / Redis) as its own user, on the NAS itself only (127.0.0.1): the Nginx app
# serves it at https://kvweb.<its domain>, asking first for the user name and password set on the app's page (kvweb has
# no login of its own). It connects to the Valkey app, with the password from Valkey's own configuration. Its data is in
# the persistent path (Nas_Prog/_kvweb - kept across reinstalls):
#   kvweb_ctl.sh setup         - create its user, folders, settings and password (where missing)
#   kvweb_ctl.sh start         - start kvweb (on 127.0.0.1:8082) once Valkey answers, checking that it's kvweb answering
#   kvweb_ctl.sh stop          - stop kvweb
#   kvweb_ctl.sh restart       - stop, then start (e.g. after Valkey's password changed - the Valkey app's page does it)
#   kvweb_ctl.sh set-password  - a new password for its site, read from the input (one line)
#   kvweb_ctl.sh nginx         - rewrite the Nginx app's sites (kvweb's comes from its nginx.json), and reload it
#   kvweb_ctl.sh daily         - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_kvweb"
BIN="${APP_PATH}/binaries"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
HTPASSWD="${DATA_PATH}/htpasswd"
KVWEB_LOG="${DATA_PATH}/kvweb.log"
PID_FILE=/var/run/kvweb.pid
PORT=8082
# The Valkey app's configuration (its port and password - root's only) and client
VALKEY_CONF="${APPS_PATH}/_valkey/valkey.conf"
VALKEY_CLI="${APPS_PATH}/valkey/binaries/valkey-cli"
# The user name its site asks for (with the password set on the page)
AUTH_USER=admin
# Its own user and group (created if missing): the IDs used when creating them
KVWEB_ID=87
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') kvweb/kvweb_ctl.sh $*" >> ${LOG}
	echo "$*"
}

# A setting from the app's settings file (written by the management page), or the default given
setting() {
	value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
	echo "${value:-$2}"
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
kvweb_ids() {
	awk -F: '$1 == "kvweb" { print $3 " " $4 }' /etc/passwd
}

# A value from Valkey's configuration (e.g. port, requirepass)
valkey_conf() {
	awk -v key="$1" '$1 == key { print $2; exit }' "${VALKEY_CONF}" 2>/dev/null
}

# The group Nginx's worker processes run as: nobody's own (nogroup on Debian - WD's NAS has none by that name: there it's
# the share users' group), by its ID, as the Nginx app picks it
nginx_gid() {
	awk -F: '$1 == "nobody" { print $4 }' /etc/passwd
}

# Writes the password (from the input) and its site's htpasswd file: SHA-512 crypt - Nginx checks it on every request, so
# not a slow hash like bcrypt. Only root and Nginx's workers (their group) can read the htpasswd file; the password
# itself is root's, for the page to show
set_password() {
	password="$(head -n 1 | tr -d '\r\n')"
	case "${password}" in
		''|*[!A-Za-z0-9._~-]*) log "Passwords are letters, digits and . _ ~ - only"; return 1 ;;
	esac
	# (the PHP app's PHP, or the NAS's own - both have SHA-512 crypt)
	php="${APPS_PATH}/php/binaries/php"
	[ -x "${php}" ] || php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
	hash="$(printf '%s' "${password}" | "${php}" -n -r '$salt = substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16);
		echo crypt(stream_get_contents(STDIN), "\$6\$rounds=5000\$" . $salt . "\$");')"
	case "${hash}" in
		'$6$'*) ;;
		*) log "Could not hash the password (is PHP working?)"; return 1 ;;
	esac
	if [ -z "$(nginx_gid)" ]; then
		log "No nobody user on the NAS: Nginx's workers couldn't read the password file"
		return 1
	fi
	umask 077
	printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}" || return 1
	printf '%s:%s\n' "${AUTH_USER}" "${hash}" > "${HTPASSWD}.tmp" && chgrp "$(nginx_gid)" "${HTPASSWD}.tmp" && chmod 640 "${HTPASSWD}.tmp" \
		&& mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^kvweb:' /etc/group || addgroup -g ${KVWEB_ID} kvweb
	grep -q '^kvweb:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${KVWEB_ID} -G kvweb kvweb
	if [ -z "$(kvweb_ids)" ]; then
		log "Could not create the kvweb user (are ID ${KVWEB_ID}'s user or group already taken?)"
		return 1
	fi

	# Its folder: root's, passable for Nginx's workers (to read the htpasswd file)
	mkdir -p "${DATA_PATH}"
	chown root:root "${DATA_PATH}"
	chmod 751 "${DATA_PATH}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'READONLY=0\n' > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	if [ ! -s "${PASSWORD_FILE}" ] || [ ! -s "${HTPASSWD}" ]; then
		log "generating the password for its site (shown on the app's page)"
		tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | set_password || return 1
	fi
	touch "${KVWEB_LOG}"
	chmod 600 "${KVWEB_LOG}"
}

# Whether Valkey answers (kvweb gives up at once if it doesn't - e.g. at boot, before the Valkey app has started)
valkey_up() {
	[ "$(REDISCLI_AUTH="$(valkey_conf requirepass)" VALKEYCLI_AUTH="$(valkey_conf requirepass)" \
		"${VALKEY_CLI}" -h 127.0.0.1 -p "$(valkey_conf port)" ping 2>/dev/null)" = PONG ]
}

# Whether it's kvweb answering (its health check names Valkey's state), while it's still running - not something else on
# the port
wait_up() {
	waited=0
	while [ ${waited} -lt 20 ]; do
		running || return 1
		curl -s -m 2 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | grep -q '"database"' && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start() {
	if running; then
		log "kvweb is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	if [ ! -f "${VALKEY_CONF}" ] || [ ! -x "${VALKEY_CLI}" ]; then
		log "The Valkey app isn't installed: kvweb shows its data"
		return 1
	fi
	if valkey_up; then
		launch
		return
	fi
	# (at boot the NAS starts its apps one after another - kvweb before Valkey - so it waits in the background, for up to
	# 10 minutes, rather than holding the others up)
	log "waiting for Valkey to answer before starting kvweb"
	(
		waited=0
		until valkey_up; do
			if [ ${waited} -ge 600 ]; then
				log "Valkey did not answer within 10 minutes: start the Valkey app, then kvweb"
				exit 1
			fi
			sleep 5
			waited=$((waited + 5))
		done
		launch
	) > /dev/null 2>&1 < /dev/null &
}

launch() {
	set -- $(kvweb_ids)
	readonly=""
	[ "$(setting READONLY 0)" = 1 ] && readonly="-readonly"
	log "starting kvweb on 127.0.0.1:${PORT}${readonly:+ (read only)}"
	# Valkey's password goes in its environment (only kvweb's user and root can read that), not on its command line. Once
	# running, it reconnects by itself if Valkey restarts
	cd "${DATA_PATH}" || return 1
	( VALKEY_PASSWORD="$(valkey_conf requirepass)" exec "${BIN}/kvweb_runas" "$1" "$2" "${BIN}/kvweb" \
		-host 127.0.0.1 -port ${PORT} -url "127.0.0.1:$(valkey_conf port)" ${readonly} ) >> "${KVWEB_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	if ! wait_up; then
		log "kvweb did not start (see ${KVWEB_LOG}): $(tail -n 2 "${KVWEB_LOG}" 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
	log "kvweb started with PID: $(cat ${PID_FILE})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping kvweb (PID ${pid})"
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

# The Nginx app finds kvweb by its folder (its nginx.json): rewrite its sites
nginx_site() {
	nginx_app="${APPS_PATH}/nginx"
	if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
		# (the NAS's php, wherever it's called from - e.g. the page, with a short PATH)
		php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
		"${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
	fi
	return 0
}

# Keeps kvweb's log under 1MB (the previous part is kept as kvweb.log.1)
rotate_log() {
	if [ "$(wc -c < "${KVWEB_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${KVWEB_LOG}" "${KVWEB_LOG}.1" && : > "${KVWEB_LOG}"
		chmod 600 "${KVWEB_LOG}.1"
	fi
}

case "$1" in
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	restart) stop; start ;;
	set-password) set_password ;;
	nginx) nginx_site ;;
	daily) rotate_log ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|set-password|nginx|daily" >&2
		exit 1
		;;
esac
