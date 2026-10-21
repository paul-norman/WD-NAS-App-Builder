#!/bin/sh
# Runs Vaultwarden as its own user, with its data in the persistent path (Nas_Prog/_vaultwarden - kept across reinstalls):
#   vw_ctl.sh setup      - create its user, folders, settings and admin token (where missing)
#   vw_ctl.sh start      - start Vaultwarden (listening on the NAS itself only - the Nginx app serves it over HTTPS)
#   vw_ctl.sh stop       - stop Vaultwarden
#   vw_ctl.sh restart    - stop, then start
#   vw_ctl.sh new-token  - generate a new admin token (applied when Vaultwarden next starts)
#   vw_ctl.sh backup     - back up the database (safely, while it runs), attachments, sends, keys and settings
#   vw_ctl.sh daily      - the daily job: a backup, and keeping the log small
#   vw_ctl.sh nginx      - add / update Vaultwarden's site in the Nginx app (and reload it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_vaultwarden"
BIN="${APP_PATH}/binaries"
VW_DATA="${DATA_PATH}/data"
SETTINGS_FILE="${DATA_PATH}/settings"
ENV_FILE="${DATA_PATH}/vaultwarden.env"
TOKEN_FILE="${DATA_PATH}/admin_token"
TOKEN_HASH_FILE="${DATA_PATH}/admin_token.hash"
VW_LOG="${DATA_PATH}/vaultwarden.log"
PID_FILE=/var/run/vaultwarden.pid
PORT=8222
# Its own user and group (created if missing): the IDs used when creating them
VW_ID=71
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') vaultwarden/vw_ctl.sh $*" >> ${LOG}
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
vw_ids() {
	awk -F: '$1 == "vaultwarden" { print $3 " " $4 }' /etc/passwd
}

new_token() {
	token="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)"
	salt="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
	# Argon2id with the parameters of Vaultwarden's documentation (and of its own "vaultwarden hash" command)
	hash="$(printf '%s' "${token}" | "${BIN}/argon2" "${salt}" -e -id -k 65540 -t 3 -p 4)"
	case "${hash}" in
		'$argon2id$'*) ;;
		*) log "Could not hash the admin token"; return 1 ;;
	esac
	( umask 077; printf '%s\n' "${token}" > "${TOKEN_FILE}.tmp" && printf '%s\n' "${hash}" > "${TOKEN_HASH_FILE}.tmp" ) || return 1
	mv -f "${TOKEN_FILE}.tmp" "${TOKEN_FILE}" && mv -f "${TOKEN_HASH_FILE}.tmp" "${TOKEN_HASH_FILE}"
	log "generated a new admin token"
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^vaultwarden:' /etc/group || addgroup -g ${VW_ID} vaultwarden
	grep -q '^vaultwarden:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${VW_ID} -G vaultwarden vaultwarden
	if [ -z "$(vw_ids)" ]; then
		log "Could not create the vaultwarden user (are ID ${VW_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(vw_ids)

	# Only root can see the settings and secrets; Vaultwarden's own data belongs to its user
	mkdir -p "${VW_DATA}"
	chmod 711 "${DATA_PATH}"
	chown "$1:$2" "${VW_DATA}"
	chmod 700 "${VW_DATA}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'SIGNUPS=1\nBACKUP_DIR=\nBACKUP_KEEP=14\n' > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	if [ ! -s "${TOKEN_HASH_FILE}" ]; then
		new_token || return 1
	fi
	touch "${VW_LOG}"
	chmod 600 "${VW_LOG}"
}

# Its environment (DOMAIN: its address in the Nginx app, so links in emails and passkeys use it)
write_env() {
	domain="$(php "${APP_PATH}/lib/vw.php" url "${APPS_PATH}" 2>/dev/null)"
	signups=false
	[ "$(setting SIGNUPS 1)" = 1 ] && signups=true
	( umask 077; cat > "${ENV_FILE}" <<EOF
DATA_FOLDER='${VW_DATA}'
WEB_VAULT_FOLDER='${BIN}/web-vault'
ROCKET_ADDRESS='127.0.0.1'
ROCKET_PORT='${PORT}'
DOMAIN='${domain%/}'
ADMIN_TOKEN='$(cat "${TOKEN_HASH_FILE}")'
SIGNUPS_ALLOWED='${signups}'
LOG_LEVEL='warn'
SSL_CERT_FILE='${BIN}/ca-certificates.crt'
EOF
	)
	# (an empty DOMAIN would be taken as a setting, so it's left out until the Nginx app has a domain)
	[ -n "${domain}" ] || sed -i '/^DOMAIN=/d' "${ENV_FILE}"
}

start() {
	if running; then
		log "Vaultwarden is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	write_env
	set -- $(vw_ids)
	log "starting Vaultwarden on 127.0.0.1:${PORT} (log: ${VW_LOG})"
	# Its log is appended to (so that it can be cut short while Vaultwarden runs)
	cd "${VW_DATA}" || return 1
	( set -a; . "${ENV_FILE}"; set +a; exec "${BIN}/vw_runas" "$1" "$2" "${BIN}/vaultwarden" ) >> "${VW_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	log "Vaultwarden started with PID: $(cat ${PID_FILE})"
}

stop() {
	if ! running; then
		rm -f "${PID_FILE}"
		return 0
	fi
	pid="$(cat "${PID_FILE}")"
	log "stopping Vaultwarden (PID ${pid})"
	kill "${pid}"
	waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ ${waited} -ge 20 ]; then
			log "Vaultwarden did not stop within 20 seconds, killing it"
			kill -9 "${pid}" 2>/dev/null
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
	rm -f "${PID_FILE}"
}

backup() {
	dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
	keep="$(setting BACKUP_KEEP 14)"
	if [ ! -f "${VW_DATA}/db.sqlite3" ]; then
		log "Nothing to back up yet (no database - create an account first)"
		return 1
	fi
	if [ ! -d "${dir}" ]; then
		mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
	fi

	stamp="$(date '+%Y%m%d-%H%M%S')"
	work="${dir}/.vaultwarden-${stamp}"
	file="${dir}/vaultwarden-${stamp}.tar.gz"
	rm -rf "${work}"
	mkdir -m 700 "${work}" || return 1
	# SQLite's online backup: a consistent copy, even while Vaultwarden writes to it
	if ! "${BIN}/sqlite3" "${VW_DATA}/db.sqlite3" ".backup '${work}/db.sqlite3'" \
		|| [ "$("${BIN}/sqlite3" "${work}/db.sqlite3" 'PRAGMA integrity_check;')" != ok ]; then
		log "The database backup failed"
		rm -rf "${work}"
		return 1
	fi
	for item in attachments sends config.json rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der; do
		[ -e "${VW_DATA}/${item}" ] && cp -a "${VW_DATA}/${item}" "${work}/"
	done
	if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . ) || ! mv -f "${file}.tmp" "${file}"; then
		log "Could not write the backup: ${file}"
		rm -rf "${work}" "${file}.tmp"
		return 1
	fi
	rm -rf "${work}"
	chmod 600 "${file}"
	log "backed up to: ${file}"

	# Keep only the newest backups
	ls -1 "${dir}"/vaultwarden-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
		rm -f "${old}"
	done
}

# Keeps Vaultwarden's log under 1MB (the previous part is kept as vaultwarden.log.1)
rotate_log() {
	if [ "$(wc -c < "${VW_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${VW_LOG}" "${VW_LOG}.1" && : > "${VW_LOG}"
		chmod 600 "${VW_LOG}.1"
	fi
}

# The Nginx app finds Vaultwarden by its folder and serves it at https://vaultwarden.<its domain>: rewrite its sites
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
	new-token) new_token ;;
	backup) backup ;;
	daily) backup; rotate_log ;;
	nginx) nginx_site ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|new-token|backup|daily|nginx" >&2
		exit 1
		;;
esac
