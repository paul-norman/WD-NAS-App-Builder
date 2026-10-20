#!/bin/sh
# Runs Nginx with its configuration in the persistent path (Nas_Prog/_nginx - kept across reinstalls):
#   nginx_ctl.sh setup    - create the configuration folders, adding the app's default files where missing
#   nginx_ctl.sh start    - check the configuration, then start Nginx
#   nginx_ctl.sh stop     - stop Nginx (letting running requests finish)
#   nginx_ctl.sh reload   - check the configuration, then reload it gracefully (Nginx keeps the old one if it's broken)
#   nginx_ctl.sh test     - check the configuration
#   nginx_ctl.sh php-restart - restart the sites' PHP (php-fpm, from the PHP app), e.g. after changing php/*.conf / ini

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_nginx"
NGINX="${APP_PATH}/binaries/nginx"
PID_FILE="${DATA_PATH}/logs/nginx.pid"

# The sites' PHP: the PHP app's php-fpm, run under another file name - WD's php-fpm.sh finds (and stops) its own php-fpm
# with pidof, which matches the program's file name (a symbolic link wouldn't do: it resolves to php-fpm), so a second
# php-fpm would be stopped with it, and could stop WD's from starting
PHP_FPM_SOURCE="$(dirname "${APP_PATH}")/php/binaries/php-fpm"
PHP_FPM="${APP_PATH}/binaries/nginx-php-fpm"
PHP_PID_FILE="${DATA_PATH}/logs/php-fpm.pid"
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') nginx/nginx_ctl.sh $*" >> ${LOG}
	echo "$*"
}

nginx() {
	"${NGINX}" -p "${DATA_PATH}/" -c "${DATA_PATH}/nginx.conf" "$@"
}

# The PIDs of Nginx's worker processes (the master's children)
workers() {
	master="$(cat "${PID_FILE}" 2>/dev/null)"
	for stat in /proc/[0-9]*/stat; do
		awk -v master="${master}" '$4 == master { print $1 }' "${stat}" 2>/dev/null
	done
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# Nginx's worker processes run as nobody, with its own group - whose name differs between systems (e.g. nogroup on
# Debian; WD's NAS has none by that name), so it's looked up. Only the app's original user line is changed
set_user() {
	conf="${DATA_PATH}/nginx.conf"
	grep -q '^user             nobody nogroup;$' "${conf}" || return 0
	grep -q '^nogroup:' /etc/group && return 0
	gid="$(awk -F: '$1 == "nobody" { print $4 }' /etc/passwd)"
	group="$(awk -F: -v gid="${gid}" '$3 == gid { print $1; exit }' /etc/group)"
	if [ -z "${group}" ]; then
		log "Nginx's worker processes can't run as nobody (no such user, or its group isn't in /etc/group)"
		return 1
	fi
	log "Nginx's worker processes run as: nobody, group ${group}"
	sed -i "s|^user             nobody nogroup;\$|user             nobody ${group};|" "${conf}"
}

setup() {
	mkdir -p "${DATA_PATH}"
	for dir in modules http.d server.d ssl.d sites params certs logs temp www/start acme; do
		mkdir -p "${DATA_PATH}/${dir}"
	done
	chmod 700 "${DATA_PATH}/certs" "${DATA_PATH}/acme"

	# The app's default files and Nginx's standard parameter files, only where missing: once there, they are the user's
	(cd "${APP_PATH}/defaults" && find . -type f) | while read -r file; do
		if [ ! -e "${DATA_PATH}/${file}" ]; then
			mkdir -p "$(dirname "${DATA_PATH}/${file}")"
			cp "${APP_PATH}/defaults/${file}" "${DATA_PATH}/${file}"
		fi
	done
	set_user

	for file in "${APP_PATH}"/params/*; do
		[ -e "${DATA_PATH}/params/$(basename "${file}")" ] || cp "${file}" "${DATA_PATH}/params/"
	done

	# The sites' PHP settings: their paths and the NAS's timezone (only where the app's placeholders are still there)
	timezone="$(sed -n 's/^date.timezone *= *//p' /etc/php/php.ini 2>/dev/null | head -n 1)"
	sed -i "s|__DATA_PATH__|${DATA_PATH}|g; s|__TIMEZONE__|${timezone:-UTC}|g" "${DATA_PATH}/php/php.ini" "${DATA_PATH}/php/php-fpm.conf"
	# PHP runs as nobody: its sessions folder and error log are its own
	mkdir -p "${DATA_PATH}/php/sessions"
	touch "${DATA_PATH}/logs/php-errors.log"
	chown nobody "${DATA_PATH}/php/sessions" "${DATA_PATH}/logs/php-errors.log" 2>/dev/null
	chmod 700 "${DATA_PATH}/php/sessions"

	# A temporary self-signed certificate until a real one is set up, then the generated sites
	if [ ! -s "${DATA_PATH}/certs/default.crt" ]; then
		log "creating a temporary self-signed certificate"
		php "${APP_PATH}/lib/sites.php" selfsigned "${DATA_PATH}"
	fi
	php "${APP_PATH}/lib/sites.php" generate "${DATA_PATH}"
}

php_running() {
	[ -f "${PHP_PID_FILE}" ] && kill -0 "$(cat "${PHP_PID_FILE}")" 2>/dev/null
}

php_start() {
	php_running && return 0
	if [ ! -x "${PHP_FPM_SOURCE}" ]; then
		log "No PHP for the sites (install the PHP app for it)"
		return 0
	fi
	# A hard link (another name for the same file, both apps being on the same volume), or else a copy
	rm -f "${PHP_FPM}"
	ln "${PHP_FPM_SOURCE}" "${PHP_FPM}" 2>/dev/null || cp "${PHP_FPM_SOURCE}" "${PHP_FPM}"
	# Files PHP creates stay writable by the NAS's users (like the shares themselves). Only its own php.ini is read (not
	# any other folder of PHP settings on the system)
	if (umask 000; PHP_INI_SCAN_DIR= "${PHP_FPM}" -c "${DATA_PATH}/php/php.ini" -y "${DATA_PATH}/php/php-fpm.conf"); then
		log "PHP for the sites started with PID: $(cat "${PHP_PID_FILE}" 2>/dev/null)"
	else
		log "PHP for the sites could not start, see: ${DATA_PATH}/logs/php-fpm.log"
		return 1
	fi
}

php_stop() {
	php_running || return 0
	pid="$(cat "${PHP_PID_FILE}")"
	# SIGQUIT lets running requests finish
	kill -QUIT "${pid}"
	waited=0
	while kill -0 "${pid}" 2>/dev/null && [ ${waited} -lt 30 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	kill -TERM "${pid}" 2>/dev/null
	log "PHP for the sites stopped"
}

start() {
	php_start
	if running; then
		log "Nginx is already running with PID: $(cat "${PID_FILE}")"
		return 0
	fi
	if ! output="$(nginx -t 2>&1)"; then
		log "Not starting Nginx - its configuration has an error: ${output}"
		return 1
	fi
	nginx && log "Nginx started with PID: $(cat "${PID_FILE}" 2>/dev/null)"
}

stop() {
	php_stop
	running || return 0
	pid="$(cat "${PID_FILE}")"
	nginx -s quit
	waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ ${waited} -ge 30 ]; then
			log "Nginx did not stop within 30 seconds, stopping it now"
			kill -TERM "${pid}" 2>/dev/null
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
	log "Nginx stopped"
}

reload() {
	if ! output="$(nginx -t 2>&1)"; then
		log "Not reloading Nginx - its configuration has an error: ${output}"
		echo "${output}" >&2
		return 1
	fi
	if running; then
		# A reload starts new worker processes in the background (the old ones finish their requests): wait for them, so
		# that the new configuration is in use when this returns
		old="$(workers | tr '\n' ' ')"
		nginx -s reload || return 1
		waited=0
		while [ ${waited} -lt 50 ]; do
			for pid in $(workers); do
				case " ${old} " in *" ${pid} "*) ;; *) log "Nginx reloaded"; return 0 ;; esac
			done
			sleep 0.1
			waited=$((waited + 1))
		done
		log "Nginx reloaded (its new worker processes didn't show within 5 seconds)"
	else
		start
	fi
}

case "$1" in
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	reload) reload ;;
	test) nginx -t ;;
	php-restart) php_stop; php_start ;;
	*) echo "Usage: $0 setup | start | stop | reload | test | php-restart"; exit 1 ;;
esac
