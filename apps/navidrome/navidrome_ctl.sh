#!/bin/sh
# Runs Navidrome (music streaming) as its own user, with its data in the persistent path (Nas_Prog/_navidrome - kept
# across reinstalls):
#   navidrome_ctl.sh setup                - create its user, folders, settings and encryption key (where missing)
#   navidrome_ctl.sh start                - write its configuration, then start it (on port 4533: the network, or the
#                                           NAS itself only). The first time, it also creates the admin user
#   navidrome_ctl.sh stop                 - stop Navidrome
#   navidrome_ctl.sh restart              - stop, then start
#   navidrome_ctl.sh new-password         - give the admin user a new (generated) password, while Navidrome runs
#   navidrome_ctl.sh check-folder <path>  - whether Navidrome's user can read a folder (exit status 0 if so)
#   navidrome_ctl.sh daily                - the daily job: keeping its log small
#   navidrome_ctl.sh nginx                - add / update Navidrome's site in the Nginx app (and reload it)
#
# It only reads the music: its user needs to be able to read the music folder (shares are normally readable by all).
# Navidrome backs its own database up every night (to backups/, keeping 7)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_navidrome"
# (PHP finds the Nginx app's address: wherever it is, also when run with a minimal PATH, e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
ND_DATA="${DATA_PATH}/data"
CONFIG="${ND_DATA}/navidrome.toml"
BACKUP_DIR="${DATA_PATH}/backups"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
KEY_FILE="${DATA_PATH}/encryption_key"
ND_LOG="${DATA_PATH}/navidrome.log"
PID_FILE=/var/run/navidrome.pid
PORT=4533
ADMIN=admin
# Its own user and group (created if missing): the IDs used when creating them
ND_ID=78
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') navidrome/navidrome_ctl.sh $*" >> ${LOG}
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
nd_ids() {
	awk -F: '$1 == "navidrome" { print $3 " " $4 }' /etc/passwd
}

# A random string of letters and digits: $1 its length
random_text() {
	tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^navidrome:' /etc/group || addgroup -g ${ND_ID} navidrome
	grep -q '^navidrome:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${ND_ID} -G navidrome navidrome
	if [ -z "$(nd_ids)" ]; then
		log "Could not create the navidrome user (are ID ${ND_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(nd_ids)

	# Its data (database, caches, its configuration - which holds the encryption key) and backups belong to its user;
	# the page's settings, the admin password and the encryption key to root
	mkdir -p "${ND_DATA}" "${BACKUP_DIR}"
	chmod 711 "${DATA_PATH}"
	chown "$1:$2" "${ND_DATA}" "${BACKUP_DIR}"
	chmod 700 "${ND_DATA}" "${BACKUP_DIR}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		# The music: WD's own music folder if there is one, otherwise the Public share
		music="/mnt/HD/HD_a2/Public/Shared Music"
		[ -d "${music}" ] || music="/mnt/HD/HD_a2/Public"
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'MUSIC_FOLDER=%s\nLISTEN=all\nEXTERNAL=0\n' "${music}" > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	# (it encrypts the users' passwords in the database - which Subsonic apps' logins need - so it never changes)
	if [ ! -s "${KEY_FILE}" ]; then
		( umask 077; random_text 32 > "${KEY_FILE}" )
	fi
	touch "${ND_LOG}"
	chmod 600 "${ND_LOG}"
}

# Its address: the Nginx app's site (HTTPS) if it has one
site_url() {
	url="$(php "${APP_PATH}/lib/navidrome.php" url "${APPS_PATH}" 2>/dev/null)"
	echo "${url%/}"
}

write_config() {
	set -- $(nd_ids)
	host=0.0.0.0
	[ "$(setting LISTEN all)" = local ] && host=127.0.0.1
	external=false
	[ "$(setting EXTERNAL 0)" = 1 ] && external=true
	# (the folder is checked by the management page: no quotes or backslashes, which would break the TOML)
	music="$(setting MUSIC_FOLDER /mnt/HD/HD_a2/Public)"
	share_url=""
	url="$(site_url)"
	[ -n "${url}" ] && share_url="ShareURL = \"${url}\""
	( umask 077; cat > "${CONFIG}.tmp" <<EOF
# Written by the Navidrome app at every start: changes here are overwritten
MusicFolder = "${music}"
DataFolder = "${ND_DATA}"
CacheFolder = "${ND_DATA}/cache"
Address = "${host}"
Port = ${PORT}
LogLevel = "warn"
FFmpegPath = "${BIN}/ffmpeg"
PasswordEncryptionKey = "$(cat "${KEY_FILE}")"
${share_url}

# Nothing sent to other sites unless turned on (artist images and biographies from Deezer, Last.fm and ListenBrainz)
EnableExternalServices = ${external}
EnableInsightsCollector = false

[Scanner]
# New and changed files are picked up as they appear, and everything is checked once a day
Schedule = "@every 24h"

[Backup]
Path = "${BACKUP_DIR}"
Schedule = "30 3 * * *"
Count = 7

[Plugins]
Enabled = false
EOF
	)
	chown "$1:$2" "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

# Waits up to 60 seconds for Navidrome to answer
wait_up() {
	waited=0
	while [ ${waited} -lt 60 ]; do
		curl -sf -o /dev/null "http://127.0.0.1:${PORT}/ping" && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start() {
	if running; then
		log "Navidrome is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	write_config || return 1
	set -- $(nd_ids)
	# The first time (no database yet), Navidrome creates the admin user: with a throwaway password, as it logs it, then
	# replaced by the real one below
	first=""
	[ -f "${ND_DATA}/navidrome.db" ] || first="ND_DEVAUTOCREATEADMINPASSWORD=$(random_text 24)"
	log "starting Navidrome on port ${PORT} (log: ${ND_LOG})"
	# Its log is appended to (so that it can be cut short while it runs)
	cd "${ND_DATA}" || return 1
	( exec env ${first} "${BIN}/navidrome_runas" "$1" "$2" "${BIN}/navidrome" --configfile "${CONFIG}" --nobanner ) \
		>> "${ND_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	log "Navidrome started with PID: $(cat ${PID_FILE})"
	if [ -n "${first}" ] || [ ! -s "${PASSWORD_FILE}" ]; then
		if wait_up; then
			new_password
		else
			log "Navidrome did not answer within 60 seconds: the admin user's password was not set"
			return 1
		fi
	fi
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping Navidrome (PID ${pid})"
		kill "${pid}"
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 20 ]; then
				log "Navidrome did not stop within 20 seconds, killing it"
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "${PID_FILE}"
}

# A new generated password for the admin user. Navidrome only reads it from a terminal: navidrome_runas --pty types it
# in (twice, as asked), so it's never on a command line
new_password() {
	set -- $(nd_ids)
	password="$(random_text 20)"
	if printf '%s\n%s\n' "${password}" "${password}" | ( cd "${ND_DATA}" && "${BIN}/navidrome_runas" --pty "$1" "$2" \
		"${BIN}/navidrome" user edit --user "${ADMIN}" --set-password --configfile "${CONFIG}" --nobanner ) > /dev/null 2>&1; then
		( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
		log "gave the admin user (${ADMIN}) a new password"
	else
		log "Could not change the admin user's password (is there still a user called ${ADMIN}?)"
		return 1
	fi
}

# Whether Navidrome's user can read a folder (and list what's in it)
check_folder() {
	set -- $(nd_ids) "$1"
	[ -d "$3" ] && "${BIN}/navidrome_runas" "$1" "$2" /bin/ls "$3" > /dev/null 2>&1
}

# Keeps Navidrome's log under 1MB (the previous part is kept as navidrome.log.1)
rotate_log() {
	if [ "$(wc -c < "${ND_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${ND_LOG}" "${ND_LOG}.1" && : > "${ND_LOG}"
		chmod 600 "${ND_LOG}.1"
	fi
}

# The Nginx app finds Navidrome by its folder and serves it at https://navidrome.<its domain>: rewrite its sites
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
	check-folder) setup > /dev/null && check_folder "$2" ;;
	daily) rotate_log ;;
	nginx) nginx_site ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|new-password|check-folder <path>|daily|nginx" >&2
		exit 1
		;;
esac
