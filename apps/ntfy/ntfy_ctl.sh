#!/bin/sh
# Runs ntfy (push notifications to phones and browsers) as its own user, with its data in the persistent path
# (Nas_Prog/_ntfy - kept across reinstalls):
#   ntfy_ctl.sh setup          - create its user, folders, settings, the admin password and the apps' token (where missing)
#   ntfy_ctl.sh start          - write its configuration, then start it (on port 2586: the network, or the NAS itself only)
#   ntfy_ctl.sh stop           - stop ntfy
#   ntfy_ctl.sh restart        - stop, then start
#   ntfy_ctl.sh new-password   - generate a new admin password (applied when ntfy next starts)
#   ntfy_ctl.sh new-token      - generate a new token for the apps (applied when ntfy next starts)
#   ntfy_ctl.sh daily          - the daily job: keeping its log small
#   ntfy_ctl.sh nginx          - add / update ntfy's site in the Nginx app (and reload it)
#
# Nobody can read or send notifications without logging in: the admin user (for the phone apps and the web app) and the
# apps' access token are declared in its configuration (only the password's bcrypt hash is written there)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_ntfy"
# (PHP hashes the admin password: wherever it is, also when run with a minimal PATH, e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
NTFY_DATA="${DATA_PATH}/data"
CONFIG="${NTFY_DATA}/server.yml"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
TOKEN_FILE="${DATA_PATH}/token"
NTFY_LOG="${DATA_PATH}/ntfy.log"
PID_FILE=/var/run/ntfy.pid
PORT=2586
# Its own user and group (created if missing): the IDs used when creating them
NTFY_ID=76
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') ntfy/ntfy_ctl.sh $*" >> ${LOG}
	echo "$*"
}

# A setting from the settings file (written by the management page), or the default given
setting() {
	value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
	echo "${value:-$2}"
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
ntfy_ids() {
	awk -F: '$1 == "ntfy" { print $3 " " $4 }' /etc/passwd
}

# Writes a secret (letters and digits) to a root-only file: $1 the file, $2 its length, $3 a prefix
new_secret() {
	( umask 077; printf '%s%s\n' "$3" "$(tr -dc 'a-z0-9' < /dev/urandom | head -c "$2")" > "$1.tmp" ) && mv -f "$1.tmp" "$1"
}

new_password() {
	( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
	log "generated a new admin password"
}

new_token() {
	# (ntfy's own token format: tk_ and 29 lower case letters and digits)
	new_secret "${TOKEN_FILE}" 29 tk_
	log "generated a new token for the apps"
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^ntfy:' /etc/group || addgroup -g ${NTFY_ID} ntfy
	grep -q '^ntfy:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${NTFY_ID} -G ntfy ntfy
	if [ -z "$(ntfy_ids)" ]; then
		log "Could not create the ntfy user (are ID ${NTFY_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(ntfy_ids)

	# Its data (messages, users, attachments, and its configuration, which holds the token) belongs to its user; the
	# settings and secrets to root
	mkdir -p "${NTFY_DATA}/attachments"
	chmod 711 "${DATA_PATH}"
	chown -R "$1:$2" "${NTFY_DATA}"
	chmod 700 "${NTFY_DATA}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'LISTEN=all\nIOS_PUSH=0\n' > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	[ -s "${PASSWORD_FILE}" ] || new_password
	[ -s "${TOKEN_FILE}" ] || new_token
	touch "${NTFY_LOG}"
	chmod 600 "${NTFY_LOG}"
}

# Its address: the Nginx app's site (HTTPS) if it has one, otherwise the NAS's own address on port 2586
base_url() {
	url="$(php "${APP_PATH}/lib/ntfy.php" url "${APPS_PATH}" 2>/dev/null)"
	if [ -z "${url}" ]; then
		ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
		url="http://${ip:-127.0.0.1}:${PORT}"
	fi
	echo "${url%/}"
}

write_config() {
	set -- $(ntfy_ids)
	host=0.0.0.0
	[ "$(setting LISTEN all)" = local ] && host=127.0.0.1
	# The admin password's bcrypt hash, made by the NAS's PHP (reading the password on its input, not its command line)
	hash="$(php -r 'echo password_hash(trim(fgets(STDIN)), PASSWORD_BCRYPT);' < "${PASSWORD_FILE}")"
	case "${hash}" in
		'$2'*) ;;
		*) log "Could not hash the admin password (is PHP working?)"; return 1 ;;
	esac
	upstream=""
	if [ "$(setting IOS_PUSH 0)" = 1 ]; then
		upstream='upstream-base-url: "https://ntfy.sh"'
	fi
	( umask 077; cat > "${CONFIG}.tmp" <<EOF
# Written by the ntfy app at every start: changes here are overwritten
base-url: "$(base_url)"
listen-http: "${host}:${PORT}"
behind-proxy: true

# Messages are kept for a day (so phones that were offline still get them), attachments up to 15MB each
cache-file: "${NTFY_DATA}/cache.db"
cache-duration: "24h"
attachment-cache-dir: "${NTFY_DATA}/attachments"

# Nobody can read or send without logging in (the web app at the same address too)
auth-file: "${NTFY_DATA}/user.db"
auth-default-access: "deny-all"
enable-login: true
enable-signup: false
enable-reservations: false
auth-users:
  - "admin:${hash}:admin"
auth-tokens:
  - "admin:$(cat "${TOKEN_FILE}"):NAS apps"

# iPhones: instant notifications through ntfy.sh's push relay (which only sees each message's ID, not its contents)
${upstream}

log-level: warn
EOF
	)
	chown "$1:$2" "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

start() {
	if running; then
		log "ntfy is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	write_config || return 1
	set -- $(ntfy_ids)
	log "starting ntfy on port ${PORT} (log: ${NTFY_LOG})"
	# Its log is appended to (so that it can be cut short while it runs)
	cd "${NTFY_DATA}" || return 1
	( exec env HOME="${NTFY_DATA}" "${BIN}/ntfy_runas" "$1" "$2" "${BIN}/ntfy" serve --config "${CONFIG}" ) >> "${NTFY_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	log "ntfy started with PID: $(cat ${PID_FILE})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping ntfy (PID ${pid})"
		kill "${pid}"
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 20 ]; then
				log "ntfy did not stop within 20 seconds, killing it"
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "${PID_FILE}"
}

# Keeps ntfy's log under 1MB (the previous part is kept as ntfy.log.1)
rotate_log() {
	if [ "$(wc -c < "${NTFY_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${NTFY_LOG}" "${NTFY_LOG}.1" && : > "${NTFY_LOG}"
		chmod 600 "${NTFY_LOG}.1"
	fi
}

# The Nginx app finds ntfy by its folder and serves it at https://ntfy.<its domain>: rewrite its sites
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
	new-password) new_password ;;
	new-token) new_token ;;
	daily) rotate_log ;;
	nginx) nginx_site ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|new-password|new-token|daily|nginx" >&2
		exit 1
		;;
esac
