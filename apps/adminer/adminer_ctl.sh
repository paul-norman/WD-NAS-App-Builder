#!/bin/sh
# Runs Adminer (a web interface for MariaDB, PostgreSQL and SQLite - one PHP file) with the PHP app's PHP 8.5 if it's
# installed, else the NAS's own PHP 7.4 (MariaDB and SQLite only: it has no PostgreSQL driver), as its own user: PHP's own
# web server, with a few workers. The Nginx app serves it at https://adminer.<its domain>, asking first for the user name
# and password set on the app's page (unless AUTH=0: before anyone reaches its form, which can connect to any server) -
# then Adminer asks for a database login. By default (LISTEN=local,
# when the Nginx app is installed) only that way: it listens on the NAS itself only (127.0.0.1). With LISTEN=all it's also
# at http://<nas-ip>:8084 on the local network, with only Adminer's own database login. Its data is in the persistent path
# (Nas_Prog/_adminer - kept across reinstalls):
#   adminer_ctl.sh setup         - create its user, folders and password (where missing)
#   adminer_ctl.sh start         - start Adminer (on port 8084), checking that it's Adminer answering
#   adminer_ctl.sh stop          - stop Adminer
#   adminer_ctl.sh restart       - stop, then start
#   adminer_ctl.sh set-password  - a new password for its site, read from the input (one line)
#   adminer_ctl.sh nginx         - rewrite the Nginx app's sites (Adminer's comes from its nginx.json), and reload it
#   adminer_ctl.sh daily         - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_adminer"
BIN="${APP_PATH}/binaries"
WWW="${APP_PATH}/www"
SESSIONS="${DATA_PATH}/sessions"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
HTPASSWD="${DATA_PATH}/htpasswd"
ADMINER_LOG="${DATA_PATH}/adminer.log"
PID_FILE=/var/run/adminer.pid
PORT=8084
# The PHP app's PHP 8.5 (with every driver Adminer uses built in), or the NAS's own PHP 7.4 (its drivers loaded by its
# php.ini - MySQL / MariaDB and SQLite, no PostgreSQL)
APP_PHP="${APPS_PATH}/php/binaries/php"
WD_PHP=/usr/local/modules/usr/bin/php
WD_PHP_INI=/etc/php/php.ini
# WD's MariaDB socket (for a login to "localhost" - 127.0.0.1 goes over TCP)
MYSQL_SOCKET=/var/lib/mysql/mysql.sock
# The user name its site asks for (with the password set on the page)
AUTH_USER=admin
# Its own user and group (created if missing): the IDs used when creating them
ADMINER_ID=88
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') adminer/adminer_ctl.sh $*" >> ${LOG}
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
adminer_ids() {
	awk -F: '$1 == "adminer" { print $3 " " $4 }' /etc/passwd
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
	grep -q '^adminer:' /etc/group || addgroup -g ${ADMINER_ID} adminer
	grep -q '^adminer:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${ADMINER_ID} -G adminer adminer
	if [ -z "$(adminer_ids)" ]; then
		log "Could not create the adminer user (are ID ${ADMINER_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(adminer_ids)

	# Its folder: root's, passable for Nginx's workers (to read the htpasswd file); its sessions (database logins) its
	# user's only
	mkdir -p "${SESSIONS}"
	chown root:root "${DATA_PATH}"
	chmod 751 "${DATA_PATH}"
	chown "$1:$2" "${SESSIONS}"
	chmod 700 "${SESSIONS}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		# (only through the Nginx app - HTTPS - when it's installed)
		listen=all
		[ -d "${APPS_PATH}/nginx" ] && listen=local
		log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
		printf 'LISTEN=%s\nAUTH=1\n' "${listen}" > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	if [ ! -s "${PASSWORD_FILE}" ] || [ ! -s "${HTPASSWD}" ]; then
		log "generating the password for its site (shown on the app's page)"
		tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | set_password || return 1
	fi
	touch "${ADMINER_LOG}"
	chown "$1:$2" "${ADMINER_LOG}"
	chmod 600 "${ADMINER_LOG}"
}

# Whether it's Adminer answering (its login page), while it's still running - not something else on the port
wait_up() {
	waited=0
	while [ ${waited} -lt 20 ]; do
		running || return 1
		curl -s -m 2 "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -q '<title>[^<]*Adminer</title>' && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start() {
	if running; then
		log "Adminer is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	if [ -x "${APP_PHP}" ]; then
		# (no php.ini: only the settings given here)
		php="${APP_PHP}"; php_ini="-n"
		which="the PHP app's PHP"
	elif [ -x "${WD_PHP}" ]; then
		# (its own php.ini, which loads its drivers; the settings given here override it)
		php="${WD_PHP}"; php_ini="-c ${WD_PHP_INI}"
		which="the NAS's own PHP (MariaDB and SQLite - the PHP app adds PostgreSQL)"
	else
		log "No PHP found to run Adminer (the PHP app's, or the NAS's own)"
		return 1
	fi
	setup || return 1
	set -- $(adminer_ids)
	host=127.0.0.1
	[ "$(setting LISTEN local)" = all ] && host=0.0.0.0
	log "starting Adminer on ${host}:${PORT}, with ${which}"
	# Imports up to 512MB (the Nginx app passes uploads of any size)
	cd "${WWW}" || return 1
	( PHP_CLI_SERVER_WORKERS=4 exec "${BIN}/adminer_runas" "$1" "$2" "${php}" ${php_ini} \
		-d session.save_path="${SESSIONS}" -d session.gc_maxlifetime=3600 \
		-d display_errors=0 -d log_errors=1 -d error_log="${ADMINER_LOG}" \
		-d memory_limit=512M -d upload_max_filesize=512M -d post_max_size=512M -d max_execution_time=600 \
		-d mysqli.default_socket="${MYSQL_SOCKET}" -d pdo_mysql.default_socket="${MYSQL_SOCKET}" \
		-S ${host}:${PORT} -t "${WWW}" ) >> "${ADMINER_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	if ! wait_up; then
		log "Adminer did not start (see ${ADMINER_LOG}): $(tail -n 2 "${ADMINER_LOG}" 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
	log "Adminer started with PID: $(cat ${PID_FILE})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping Adminer (PID ${pid})"
		# (its workers first: they're its children - found by their parent, as BusyBox's pkill may lack -P)
		for proc in /proc/[0-9]*; do
			[ "$(awk '{ print $4 }' "${proc}/stat" 2>/dev/null)" = "${pid}" ] && kill "${proc#/proc/}" 2>/dev/null
		done
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
	"auth_file": "_adminer/htpasswd"'
	printf '{\n\t"name": "adminer",\n\t"label": "Adminer",\n\t"target": "http://127.0.0.1:%s",\n\t"uploads": true%s\n}\n' "${PORT}" "${auth}" \
		> "${APP_PATH}/nginx.json.tmp" && chmod 644 "${APP_PATH}/nginx.json.tmp" && mv -f "${APP_PATH}/nginx.json.tmp" "${APP_PATH}/nginx.json"
}

# The Nginx app finds Adminer by its folder (its nginx.json): rewrite its sites
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

# Keeps Adminer's log under 1MB (PHP's server logs every request; the previous part is kept as adminer.log.1)
rotate_log() {
	if [ "$(wc -c < "${ADMINER_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${ADMINER_LOG}" "${ADMINER_LOG}.1" && : > "${ADMINER_LOG}"
		chmod 600 "${ADMINER_LOG}.1"
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
