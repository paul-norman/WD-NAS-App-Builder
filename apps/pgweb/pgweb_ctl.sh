#!/bin/sh
# Runs pgweb (a web interface for PostgreSQL) as its own user. The Nginx app serves it at https://pgweb.<its domain> - by
# default (LISTEN=local, when the Nginx app is installed) only that way: pgweb then listens on the NAS itself only
# (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:8081 on the local network. Unless AUTH=0, it asks first for
# the user name and password set on the app's page (Nginx checks them; on the network, pgweb's own login - its password
# then on its command line, which other programs on the NAS can read): before anyone reaches its form, which can connect
# to any server. Each visitor then logs in to PostgreSQL itself. Its data is in the persistent path (Nas_Prog/_pgweb - kept
# across reinstalls):
#   pgweb_ctl.sh setup         - create its user, folders, settings and password (where missing)
#   pgweb_ctl.sh start         - start pgweb (on port 8081), checking that it's pgweb answering
#   pgweb_ctl.sh stop          - stop pgweb
#   pgweb_ctl.sh restart       - stop, then start
#   pgweb_ctl.sh set-password  - a new password for its site, read from the input (one line)
#   pgweb_ctl.sh nginx         - rewrite the Nginx app's sites (pgweb's comes from its nginx.json), and reload it
#   pgweb_ctl.sh daily         - keep its log small
#
# Each visitor then logs in to PostgreSQL itself on pgweb's own form (e.g. 127.0.0.1, port 5432, a database user and
# its password - see the PostgreSQL app's page)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_pgweb"
BIN="${APP_PATH}/binaries"
HOME_PATH="${DATA_PATH}/home"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
HTPASSWD="${DATA_PATH}/htpasswd"
PGWEB_LOG="${DATA_PATH}/pgweb.log"
PID_FILE=/var/run/pgweb.pid
PORT=8081
# The user name its site asks for (with the password set on the page)
AUTH_USER=admin
# Its own user and group (created if missing): the IDs used when creating them
PGWEB_ID=86
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') pgweb/pgweb_ctl.sh $*" >> ${LOG}
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
pgweb_ids() {
	awk -F: '$1 == "pgweb" { print $3 " " $4 }' /etc/passwd
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
	grep -q '^pgweb:' /etc/group || addgroup -g ${PGWEB_ID} pgweb
	grep -q '^pgweb:' /etc/passwd || adduser -D -H -h "${HOME_PATH}" -s /bin/false -u ${PGWEB_ID} -G pgweb pgweb
	if [ -z "$(pgweb_ids)" ]; then
		log "Could not create the pgweb user (are ID ${PGWEB_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(pgweb_ids)

	# Its folder: root's, passable for Nginx's workers (to read the htpasswd file); its home (bookmarks, saved queries)
	# its user's
	mkdir -p "${HOME_PATH}"
	chown root:root "${DATA_PATH}"
	chmod 751 "${DATA_PATH}"
	chown "$1:$2" "${HOME_PATH}"
	chmod 700 "${HOME_PATH}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		# (only through the Nginx app - HTTPS - when it's installed)
		listen=all
		[ -d "${APPS_PATH}/nginx" ] && listen=local
		log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
		printf 'READONLY=0\nLISTEN=%s\nAUTH=1\n' "${listen}" > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	if [ ! -s "${PASSWORD_FILE}" ] || [ ! -s "${HTPASSWD}" ]; then
		log "generating the password for its site (shown on the app's page)"
		tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | set_password || return 1
	fi
	touch "${PGWEB_LOG}"
	chmod 600 "${PGWEB_LOG}"
}

# Whether it's pgweb answering (its API names it), while it's still running - not something else on the port
wait_up() {
	waited=0
	while [ ${waited} -lt 20 ]; do
		running || return 1
		# (with its own login when on the network: given to curl on its input, not its command line)
		printf 'user = "%s:%s"\n' "${AUTH_USER}" "$(cat "${PASSWORD_FILE}")" \
			| curl -s -m 2 -K - "http://127.0.0.1:${PORT}/api/info" 2>/dev/null | grep -q '"version"' && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start() {
	if running; then
		log "pgweb is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	set -- $(pgweb_ids)
	readonly=""
	[ "$(setting READONLY 0)" = 1 ] && readonly="--readonly"
	host=127.0.0.1
	[ "$(setting LISTEN local)" = all ] && host=0.0.0.0
	log "starting pgweb on ${host}:${PORT}${readonly:+ (read only)}"
	# --sessions: each visitor logs in to PostgreSQL on its own; --no-ssh: no tunnels through it to other machines. On the
	# network, pgweb's own login too (through Nginx, the browser sends the same user name and password to both)
	cd "${HOME_PATH}" || return 1
	if [ "${host}" = 0.0.0.0 ] && [ "$(setting AUTH 1)" = 1 ]; then
		( HOME="${HOME_PATH}" exec "${BIN}/pgweb_runas" "$1" "$2" "${BIN}/pgweb" \
			--bind=${host} --listen=${PORT} --sessions --no-ssh --skip-open --log-level=warn ${readonly} \
			--auth-user="${AUTH_USER}" --auth-pass="$(cat "${PASSWORD_FILE}")" ) >> "${PGWEB_LOG}" 2>&1 &
	else
		( HOME="${HOME_PATH}" exec "${BIN}/pgweb_runas" "$1" "$2" "${BIN}/pgweb" \
			--bind=${host} --listen=${PORT} --sessions --no-ssh --skip-open --log-level=warn ${readonly} ) >> "${PGWEB_LOG}" 2>&1 &
	fi
	echo $! > "${PID_FILE}"
	if ! wait_up; then
		log "pgweb did not start (see ${PGWEB_LOG}): $(tail -n 2 "${PGWEB_LOG}" 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
	log "pgweb started with PID: $(cat ${PID_FILE})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping pgweb (PID ${pid})"
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

# Its site in the Nginx app: its nginx.json (which the Nginx app reads), with its password file unless AUTH=0. The
# package's own asks for the password, until this has run
write_nginx_json() {
	auth=""
	[ "$(setting AUTH 1)" = 1 ] && auth=',
	"auth_file": "_pgweb/htpasswd"'
	printf '{\n\t"name": "pgweb",\n\t"label": "pgweb (PostgreSQL)",\n\t"target": "http://127.0.0.1:%s"%s\n}\n' "${PORT}" "${auth}" \
		> "${APP_PATH}/nginx.json.tmp" && chmod 644 "${APP_PATH}/nginx.json.tmp" && mv -f "${APP_PATH}/nginx.json.tmp" "${APP_PATH}/nginx.json"
}

# The Nginx app finds pgweb by its folder (its nginx.json): rewrite its sites
nginx_site() {
	write_nginx_json
	nginx_app="${APPS_PATH}/nginx"
	if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
		# (the NAS's php, wherever it's called from - e.g. the page, with a short PATH)
		php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
		"${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
	fi
	return 0
}

# Keeps pgweb's log under 1MB (the previous part is kept as pgweb.log.1)
rotate_log() {
	if [ "$(wc -c < "${PGWEB_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${PGWEB_LOG}" "${PGWEB_LOG}.1" && : > "${PGWEB_LOG}"
		chmod 600 "${PGWEB_LOG}.1"
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
