#!/bin/sh
# Test PHP 8.5 as a full replacement for the NAS's own PHP 7.4 (its web interface and its PHP scripts), with every error
# logged. Run from the folder holding the php and php-fpm binaries built by static/php. Nothing is permanent: / and /etc
# are in RAM, so a reboot restores everything too.
#
#   php85-test.sh swap      - switch to PHP 8.5 (WD's php.ini and php-fpm.conf are backed up first)
#   php85-test.sh restore   - switch back to WD's PHP 7.4
#   php85-test.sh status    - which PHP is serving the web interface
#   php85-test.sh log       - the errors logged so far

DIR="$(cd "$(dirname "$0")" && pwd)"
WD_PHP=/usr/local/modules/usr/bin/php
WD_FPM=/usr/local/modules/usr/sbin/php-fpm
INI=/etc/php/php.ini
FPM_CONF=/etc/php/php-fpm.conf
WD_PAGES=/usr/local/modules/web/pages
PATCHED="${DIR}/patched"
ERROR_LOG=/tmp/php85-errors.log
FPM_LOG=/tmp/php85-fpm.log

swap() {
	if [ "$(readlink /usr/sbin/php-fpm)" = "${DIR}/php-fpm" ]; then
		echo "Already using PHP 8.5"
		return 0
	fi
	if ! "${DIR}/php" -v > /dev/null 2>&1 || ! "${DIR}/php-fpm" -v > /dev/null 2>&1; then
		echo "The PHP 8.5 binaries don't run: ${DIR}/php, ${DIR}/php-fpm"
		exit 1
	fi

	# Keep WD's own files to restore later
	[ -f "${INI}.wd" ] || cp -p "${INI}" "${INI}.wd"
	[ -f "${FPM_CONF}.wd" ] || cp -p "${FPM_CONF}" "${FPM_CONF}.wd"

	# Fresh logs for each test
	: > "${ERROR_LOG}"
	: > "${FPM_LOG}"

	# WD's PHP 7.4 code that PHP 8 refuses to run, patched in copies placed over WD's own (read-only) files
	patch_wd_files

	# apcu is built into PHP 8.5 (it can't load PHP 7.4's apcu.so), and log every error, including deprecations. Later
	# settings override earlier ones, so they are added at the end
	sed -i 's|^extension=apcu.so|;extension=apcu.so (built into PHP 8.5)|' "${INI}"
	cat >> "${INI}" <<-EOF

	; Added by php85-test.sh
	[PHP]
	error_reporting = E_ALL
	log_errors = On
	error_log = ${ERROR_LOG}
	; WD's web pages don't use \$argv (its command line scripts always get it), so stop PHP 8.5 warning about it
	register_argc_argv = Off
	opcache.memory_consumption = 64
	EOF
	sed -i "s|^error_log = .*|error_log = ${FPM_LOG}|; s|^log_level = .*|log_level = notice|" "${FPM_CONF}"
	grep -q '^catch_workers_output' "${FPM_CONF}" || echo "catch_workers_output = yes" >> "${FPM_CONF}"

	# Point the system's PHP at PHP 8.5, then restart php-fpm with WD's own script (which monit also uses)
	ln -sf "${DIR}/php-fpm" /usr/sbin/php-fpm
	ln -sf "${DIR}/php" /usr/bin/php
	/usr/sbin/php-fpm.sh restart
	status
}

restore() {
	ln -sf "${WD_FPM}" /usr/sbin/php-fpm
	ln -sf "${WD_PHP}" /usr/bin/php
	[ -f "${INI}.wd" ] && mv "${INI}.wd" "${INI}"
	[ -f "${FPM_CONF}.wd" ] && mv "${FPM_CONF}.wd" "${FPM_CONF}"
	unpatch_wd_files
	/usr/sbin/php-fpm.sh restart
	status
}

# Applies one fix to a copy of one of WD's files: $1 = file (under WD_PAGES), $2 = WD's exact code, $3 = the fix. Only
# applied when WD's code is found exactly as expected
patch() {
	copy="${PATCHED}/$1"
	[ -f "${copy}" ] || { mkdir -p "$(dirname "${copy}")" && cp "${WD_PAGES}/$1" "${copy}"; }
	if grep -qF -- "$2" "${copy}"; then
		# (each match is replaced once, carrying on after it, as the fix may contain WD's code)
		FROM="$2" TO="$3" awk '{
			out = ""; rest = $0
			while ((i = index(rest, ENVIRON["FROM"])) > 0) {
				out = out substr(rest, 1, i - 1) ENVIRON["TO"]; rest = substr(rest, i + length(ENVIRON["FROM"]))
			}
			print out rest
		}' "${copy}" > "${copy}.tmp" && mv "${copy}.tmp" "${copy}"
		echo "Patched $1: $2"
	else
		echo "NOT patched $1 (WD's code isn't as expected): $2"
	fi
}

patch_wd_files() {
	rm -rf "${PATCHED}"
	# $_SERVER[QUERY_STRING] without quotes: PHP 7 guessed the string 'QUERY_STRING', PHP 8 stops with an error
	patch cgi_api.php '$_SERVER[QUERY_STRING]' "\$_SERVER['QUERY_STRING']"
	# A property set on a variable that was never created: PHP 7 made an empty object, PHP 8 stops with an error
	patch cgi_api.php '$r->ip_address = gethostbyname(' '$r = new stdClass(); $r->ip_address = gethostbyname('
	# array_key_exists() on the token, which is usually a string: PHP 7 warned, PHP 8 stops with an error
	patch restSDK/cloudAccess.php "if(array_key_exists('statusCode', \$id_token)) {" \
		"if(is_array(\$id_token) && array_key_exists('statusCode', \$id_token)) {"

	# Each copy goes over WD's file (removed again by restore, or a reboot)
	for copy in $(cd "${PATCHED}" && find . -type f -name '*.php'); do
		file="${copy#./}"
		/usr/local/modules/usr/bin/php -l "${PATCHED}/${file}" > /dev/null 2>&1 || "${DIR}/php" -l "${PATCHED}/${file}" > /dev/null \
			|| { echo "Not using the patched ${file}: it doesn't parse"; continue; }
		grep -q " ${WD_PAGES}/${file} " /proc/mounts || mount --bind "${PATCHED}/${file}" "${WD_PAGES}/${file}"
	done
}

unpatch_wd_files() {
	for mnt in $(awk -v pages="${WD_PAGES}/" 'index($2, pages) == 1 { print $2 }' /proc/mounts); do
		umount "${mnt}" && echo "Removed the patch over ${mnt}"
	done
}

status() {
	echo "CLI (/usr/bin/php): $(/usr/bin/php -v 2>&1 | head -n 1)"
	echo "FPM (/usr/sbin/php-fpm): $(/usr/sbin/php-fpm -v 2>&1 | head -n 1)"
	pid="$(cat /var/run/php-fpm.pid 2>/dev/null)"
	if [ -n "${pid}" ] && [ -e "/proc/${pid}" ]; then
		echo "Running php-fpm: $(readlink "/proc/${pid}/exe") (PID ${pid})"
	else
		echo "php-fpm is not running!"
	fi
}

case "$1" in
	swap) swap ;;
	restore) restore ;;
	status) status ;;
	log)
		echo "== ${ERROR_LOG}"; cat "${ERROR_LOG}" 2>/dev/null
		echo "== ${FPM_LOG}"; cat "${FPM_LOG}" 2>/dev/null
		;;
	*) echo "Usage: $0 swap | restore | status | log"; exit 1 ;;
esac
