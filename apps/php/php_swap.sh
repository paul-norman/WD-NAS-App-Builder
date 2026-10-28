#!/bin/sh
# Makes PHP 8.5 the NAS's own PHP (its web interface, and the scripts it runs with /usr/bin/php), in place of WD's
# PHP 7.4 - and back again. / and /etc are in RAM, so this is applied on every boot (start.sh) and nothing outlives a
# reboot without it.
#
#   php_swap.sh swap      - switch to PHP 8.5
#   php_swap.sh restore   - switch back to WD's PHP 7.4
#   php_swap.sh status    - which PHP is in use
#   php_swap.sh rotate    - rotate the error log once it is too big (daily, from root's crontab)
#
# WD's web interface is served by php-fpm (WD's own php-fpm.sh starts it by name from the PATH, and monit watches it),
# through the socket Apache uses, so pointing /usr/sbin/php-fpm and /usr/bin/php at PHP 8.5 and restarting it is all it
# takes. Three lines of WD's PHP 7.4 code that PHP 8 refuses to run are patched, in copies placed over WD's own
# (read-only) files with bind mounts.

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_php"
WD_PHP=/usr/local/modules/usr/bin/php
WD_FPM=/usr/local/modules/usr/sbin/php-fpm
WD_PAGES=/usr/local/modules/web/pages
INI=/etc/php/php.ini
PATCHED="${APP_PATH}/patched"
ERROR_LOG="${DATA_PATH}/php-errors.log"
ERROR_LOG_MAX=262144
RESTART_PID_FILE=/var/run/php_app_restart.pid
MARK_BEGIN="; --- added by the php app ---"
MARK_END="; --- end of the php app's settings ---"
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') php/php_swap.sh $*" >> ${LOG}
	echo "$*"
}

# The binary of the running php-fpm (WD's or the app's)
serving() {
	pid="$(cat /var/run/php-fpm.pid 2>/dev/null)"
	[ -n "${pid}" ] && readlink "/proc/${pid}/exe" 2>/dev/null
}

# Applies one fix to a copy of one of WD's files: $1 = file (under WD_PAGES), $2 = WD's exact code, $3 = the fix. Fails
# if WD's code isn't found exactly as expected (WD's files then aren't the ones the fixes were made for)
patch() {
	copy="${PATCHED}/$1"
	[ -f "${copy}" ] || { mkdir -p "$(dirname "${copy}")" && cp "${WD_PAGES}/$1" "${copy}"; } || return 1
	if ! grep -qF -- "$2" "${copy}"; then
		log "WD's code isn't as expected in $1: $2"
		return 1
	fi
	# (each match is replaced once, carrying on after it, as the fix may contain WD's code)
	FROM="$2" TO="$3" awk '{
		out = ""; rest = $0
		while ((i = index(rest, ENVIRON["FROM"])) > 0) {
			out = out substr(rest, 1, i - 1) ENVIRON["TO"]; rest = substr(rest, i + length(ENVIRON["FROM"]))
		}
		print out rest
	}' "${copy}" > "${copy}.tmp" && mv "${copy}.tmp" "${copy}"
}

patch_wd_files() {
	unpatch_wd_files
	rm -rf "${PATCHED}"
	# $_SERVER[QUERY_STRING] without quotes: PHP 7 guessed the string 'QUERY_STRING', PHP 8 stops with an error
	patch cgi_api.php '$_SERVER[QUERY_STRING]' "\$_SERVER['QUERY_STRING']" || return 1
	# A property set on a variable that was never created: PHP 7 made an empty object, PHP 8 stops with an error
	patch cgi_api.php '$r->ip_address = gethostbyname(' '$r = new stdClass(); $r->ip_address = gethostbyname(' || return 1
	# array_key_exists() on the token, which is usually a string: PHP 7 warned, PHP 8 stops with an error
	patch restSDK/cloudAccess.php "if(array_key_exists('statusCode', \$id_token)) {" \
		"if(is_array(\$id_token) && array_key_exists('statusCode', \$id_token)) {" || return 1

	# Each copy goes over WD's file
	for copy in $(cd "${PATCHED}" && find . -type f -name '*.php'); do
		file="${copy#./}"
		if ! "${APP_PATH}/binaries/php" -l "${PATCHED}/${file}" > /dev/null 2>&1; then
			log "The patched ${file} doesn't parse"
			return 1
		fi
		mount --bind "${PATCHED}/${file}" "${WD_PAGES}/${file}" || return 1
	done
}

# Only the app's own copies: other apps mount theirs over WD's pages too (e.g. the Store's Apps page, addons/app.php)
unpatch_wd_files() {
	for file in cgi_api.php restSDK/cloudAccess.php $(cd "${PATCHED}" 2>/dev/null && find . -type f -name '*.php' | sed 's|^\./||'); do
		mnt="${WD_PAGES}/${file}"
		while awk -v mnt="${mnt}" '$2 == mnt { found = 1 } END { exit !found }' /proc/mounts; do
			umount "${mnt}" 2>/dev/null || umount -l "${mnt}" || break
		done
	done
}

# WD's php.ini, with the app's settings (between markers, so that they can be taken out again - WD may rewrite the file
# itself, e.g. for a new timezone, so it isn't restored from a copy)
configure_ini() {
	unconfigure_ini
	# apcu is built into PHP 8.5, which can't load PHP 7.4's apcu.so
	sed -i 's|^extension=apcu.so|;extension=apcu.so (built into PHP 8.5)|' "${INI}"
	# Later settings override earlier ones, so they go at the end
	cat >> "${INI}" <<-EOF
	${MARK_BEGIN}
	[PHP]
	; Real errors only (not deprecations or notices) - WD's own PHP 7.4 code causes plenty of those
	error_reporting = E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_USER_DEPRECATED & ~E_USER_NOTICE
	log_errors = On
	error_log = ${ERROR_LOG}
	; WD's web pages don't use \$argv (its command line scripts always get it), and PHP 8.5 warns about it
	register_argc_argv = Off
	opcache.memory_consumption = 64
	${MARK_END}
	EOF
}

unconfigure_ini() {
	sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d; s|^;extension=apcu.so (built into PHP 8.5)|extension=apcu.so|" "${INI}"
}

# Switches the running php-fpm to whichever binary /usr/sbin/php-fpm now points at, without a restart: on a graceful
# reload (SIGUSR2, as WD's php-fpm.sh reload sends) php-fpm lets running requests finish, then starts its binary again by
# the name it was started with ("php-fpm", from the PATH), keeping its PID and its socket - so requests in the meantime
# wait instead of failing (a restart leaves seconds without a socket, which hangs the NAS's web interface). Then checks,
# in the background, that the expected binary is serving: $1 = the binary, $2 = "fallback" to switch back to PHP 7.4
# (with a full restart) if it doesn't
reload() {
	if [ -f "${RESTART_PID_FILE}" ]; then
		kill "$(cat "${RESTART_PID_FILE}")" 2>/dev/null
	fi
	if [ -z "$(serving)" ]; then
		/usr/sbin/php-fpm.sh start > /dev/null 2>&1
	else
		/usr/sbin/php-fpm.sh reload > /dev/null 2>&1
	fi
	target="$(readlink -f "$1")"
	(
		trap 'exit 0' TERM
		# Running requests may take a while to finish (php-fpm's process_control_timeout is 60s), while the old php-fpm
		# carries on - but if none is running for a few seconds, the new binary failed to start
		waited=0
		gone=0
		while [ "$(serving)" != "${target}" ] && [ ${waited} -lt 90 ] && [ ${gone} -lt 3 ]; do
			sleep 1
			waited=$((waited + 1))
			if [ -z "$(serving)" ]; then gone=$((gone + 1)); else gone=0; fi
		done
		rm -f "${RESTART_PID_FILE}"
		if [ "$(serving)" = "${target}" ]; then
			log "php-fpm is now: $1 (after ${waited}s)"
		elif [ "$2" = fallback ]; then
			log "PHP 8.5 isn't serving ($(serving)), so switching back to PHP 7.4"
			restore_now
			/usr/sbin/php-fpm.sh restart > /dev/null 2>&1
		else
			log "php-fpm didn't switch to $1 ($(serving)), restarting it"
			/usr/sbin/php-fpm.sh restart > /dev/null 2>&1
		fi
	) < /dev/null > /dev/null 2>&1 &
	echo $! > "${RESTART_PID_FILE}"
}

swap() {
	if ! "${APP_PATH}/binaries/php" -v > /dev/null 2>&1 || ! "${APP_PATH}/binaries/php-fpm" -v > /dev/null 2>&1; then
		log "Not switching to PHP 8.5: its binaries don't run on this NAS"
		return 1
	fi
	if ! patch_wd_files; then
		log "Not switching to PHP 8.5: WD's PHP code couldn't be patched (unknown firmware?)"
		unpatch_wd_files
		return 1
	fi

	mkdir -p "${DATA_PATH}"
	rotate
	configure_ini
	ln -sf "${APP_PATH}/binaries/php-fpm" /usr/sbin/php-fpm
	ln -sf "${APP_PATH}/binaries/php" /usr/bin/php
	log "Switching to PHP 8.5"
	reload "${APP_PATH}/binaries/php-fpm" fallback
}

# Puts WD's PHP 7.4 back, apart from restarting php-fpm
restore_now() {
	ln -sf "${WD_FPM}" /usr/sbin/php-fpm
	ln -sf "${WD_PHP}" /usr/bin/php
	unconfigure_ini
	unpatch_wd_files
}

restore() {
	restore_now
	log "Switching back to PHP 7.4"
	reload "${WD_FPM}"
}

status() {
	echo "Serving: $(serving)"
	echo "CLI: $(/usr/bin/php -v 2>&1 | head -n 1)"
	echo "Patched files: $(awk -v pages="${WD_PAGES}/" 'index($2, pages) == 1 { printf "%s ", $2 }' /proc/mounts)"
}

# Keeps the error log small: once it's over 256KB it becomes php-errors.log.1 (PHP opens the log for each error, so it
# starts a new one by itself)
rotate() {
	if [ -f "${ERROR_LOG}" ] && [ "$(wc -c < "${ERROR_LOG}")" -gt ${ERROR_LOG_MAX} ]; then
		mv -f "${ERROR_LOG}" "${ERROR_LOG}.1"
	fi
}

case "$1" in
	swap) swap ;;
	restore) restore ;;
	status) status ;;
	rotate) rotate ;;
	*) echo "Usage: $0 swap | restore | status | rotate"; exit 1 ;;
esac
