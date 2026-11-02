#!/bin/sh
# Runs Uptime Kuma as its own user, with its data in the persistent path (Nas_Prog/_uptime-kuma - kept across
# reinstalls):
#   kuma_ctl.sh setup          - create its user, folders and settings (where missing)
#   kuma_ctl.sh start          - start Uptime Kuma (on port 3001: the whole network, or only the NAS itself for the Nginx app)
#   kuma_ctl.sh stop           - stop Uptime Kuma
#   kuma_ctl.sh restart        - stop, then start
#   kuma_ctl.sh reset-password - set the admin account's password to the one given on standard input
#   kuma_ctl.sh backup         - back up the database (safely, while it runs) and its uploads
#   kuma_ctl.sh daily          - the daily job: a backup, and keeping the log small
#   kuma_ctl.sh nginx          - add / update Uptime Kuma's site in the Nginx app (and reload it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_uptime-kuma"
BIN="${APP_PATH}/binaries"
KUMA_DATA="${DATA_PATH}/data"
SETTINGS_FILE="${DATA_PATH}/settings"
KUMA_LOG="${DATA_PATH}/uptime-kuma.log"
PID_FILE=/var/run/uptime-kuma.pid
PORT=3001
# Its own user and group (created if missing): the IDs used when creating them
KUMA_ID=72
# Unprivileged pings: the kernel's setting, and a note that the app turned it on (so that it turns it off again)
PING_RANGE=/proc/sys/net/ipv4/ping_group_range
PING_MARKER=/var/run/uptime-kuma.ping
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') uptime-kuma/kuma_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether the app's process is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
kuma_ids() {
    awk -F: '$1 == "uptimekuma" { print $3 " " $4 }' /etc/passwd
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^uptimekuma:' /etc/group || addgroup -g ${KUMA_ID} uptimekuma
    grep -q '^uptimekuma:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${KUMA_ID} -G uptimekuma uptimekuma

    if [ -z "$(kuma_ids)" ]; then
        log "Could not create the uptimekuma user (are ID ${KUMA_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(kuma_ids)

    # Only root can see the settings and backups; Uptime Kuma's own data belongs to its user
    mkdir -p "${KUMA_DATA}"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${KUMA_DATA}"
    chmod 700 "${KUMA_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LISTEN=all\nBACKUP_DIR=\nBACKUP_KEEP=7\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${KUMA_LOG}"
    chmod 600 "${KUMA_LOG}"
}

# Ping monitors run the app's own ping (iputils), which pings without root through the kernel's ICMP sockets - for the
# groups in net.ipv4.ping_group_range. It's off on the NAS ("1 0"): turned on for Uptime Kuma's group only
ping_allow() {
    set -- $(cat "${PING_RANGE}" 2>/dev/null) "$1"
    gid=$3

    if [ -z "$2" ] || { [ "$1" -le "${gid}" ] && [ "$2" -ge "${gid}" ]; }; then
        return 0
    fi

    if [ "$1" -gt "$2" ]; then
        echo "${gid} ${gid}" > "${PING_RANGE}" && echo "${gid} ${gid}" > "${PING_MARKER}"
        log "allowed unprivileged pings for group ${gid} (net.ipv4.ping_group_range)"
    else
        log "WARNING: net.ipv4.ping_group_range is set to '$1 $2' by something else, so ping monitors won't work"
    fi
}

# Turns unprivileged pings off again, if the app turned them on (and nothing changed them since)
ping_restore() {
    if [ -f "${PING_MARKER}" ] && [ "$(cat "${PING_RANGE}" | tr -s ' \t' '  ')" = "$(cat "${PING_MARKER}")" ]; then
        echo '1 0' > "${PING_RANGE}"
    fi

    rm -f "${PING_MARKER}"
}

start() {
    if running; then
        log "Uptime Kuma is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    set -- $(kuma_ids)
    ping_allow "$2"
    host=0.0.0.0
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1
    log "starting Uptime Kuma on ${host}:${PORT} (log: ${KUMA_LOG})"
    # Its log is appended to (so that it can be cut short while it runs); its own folder first in PATH, for its ping
    cd "${BIN}/uptime-kuma" || return 1
    ( exec env DATA_DIR="${KUMA_DATA}/" UPTIME_KUMA_HOST="${host}" UPTIME_KUMA_PORT="${PORT}" UPTIME_KUMA_DB_TYPE=sqlite \
        NODE_ENV=production HOME="${KUMA_DATA}" PATH="${BIN}:/usr/sbin:/usr/bin:/sbin:/bin" \
        "${BIN}/kuma_runas" "$1" "$2" "${BIN}/node" server/server.js ) >> "${KUMA_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Uptime Kuma started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Uptime Kuma (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Uptime Kuma did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
    ping_restore
}

# With Uptime Kuma's own tool (through lib/reset-password.js), run as its user: the new password is read from standard
# input (never on a command line, which other processes can see), and every login session is ended
reset_password() {
    set -- $(kuma_ids)
    cd "${BIN}/uptime-kuma" || return 1
    env DATA_DIR="${KUMA_DATA}/" UPTIME_KUMA_PORT="${PORT}" UPTIME_KUMA_DB_TYPE=sqlite HOME="${KUMA_DATA}" \
        "${BIN}/kuma_runas" "$1" "$2" "${BIN}/node" "${APP_PATH}/lib/reset-password.js" 2>&1
}

backup() {
    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -f "${KUMA_DATA}/kuma.db" ]; then
        log 'Nothing to back up yet (no database - open Uptime Kuma to set it up first)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    stamp="$(date '+%Y%m%d-%H%M%S')"
    work="${dir}/.uptime-kuma-${stamp}"
    file="${dir}/uptime-kuma-${stamp}.tar.gz"
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    # SQLite's online backup: a consistent copy, even while Uptime Kuma writes to it (and no ~/.sqliterc read: -init
    # /dev/null)
    if ! "${BIN}/sqlite3" -init /dev/null "${KUMA_DATA}/kuma.db" ".backup '${work}/kuma.db'" \
        || [ "$("${BIN}/sqlite3" -init /dev/null "${work}/kuma.db" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    for item in db-config.json upload docker-tls; do
        [ -e "${KUMA_DATA}/${item}" ] && cp -a "${KUMA_DATA}/${item}" "${work}/"
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
    ls -1 "${dir}"/uptime-kuma-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps Uptime Kuma's log under 1MB (the previous part is kept as uptime-kuma.log.1)
rotate_log() {
    if [ "$(wc -c < "${KUMA_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${KUMA_LOG}" "${KUMA_LOG}.1" && : > "${KUMA_LOG}"
        chmod 600 "${KUMA_LOG}.1"
    fi
}

# The Nginx app finds Uptime Kuma by its folder and serves it at https://uptime-kuma.<its domain>: rewrite its sites
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
    reset-password) reset_password ;;
    backup) backup ;;
    daily) backup; rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|reset-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
