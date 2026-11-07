#!/bin/sh
# Runs qBittorrent (its headless qbittorrent-nox: BitTorrent with a web interface) as its own user, in the NAS's share
# group, with its data in the persistent path Nas_Prog/_qbittorrent - kept across reinstalls. Run by the app's scripts
# and its management page:
#   qbt_ctl.sh setup        - create its user, folders, settings and web interface password (where missing)
#   qbt_ctl.sh start        - write its settings into qBittorrent's own, then start it (web interface on port 8092)
#   qbt_ctl.sh stop         - stop qBittorrent (it saves its torrents' progress first)
#   qbt_ctl.sh restart      - stop, then start
#   qbt_ctl.sh new-password - generate a new web interface password (applied when qBittorrent next starts)
#   qbt_ctl.sh daily        - the daily job: keeping its console log small
#   qbt_ctl.sh nginx        - add / update qBittorrent's site in the Nginx app (and reload it)
#
# Its downloads go to a folder in the shares (a Downloads share if there is one, else Public/Downloads), readable and
# writable by the NAS's users: qBittorrent runs in the share group, with a umask that keeps its files group-writable

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
VOLUME_PATH="$(dirname "${APPS_PATH}")"
DATA_PATH="${APPS_PATH}/_qbittorrent"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
# qBittorrent's own data (its settings, torrents and their progress): its profile, <profile>/qBittorrent/...
PROFILE="${DATA_PATH}/profile"
CONF="${PROFILE}/qBittorrent/config/qBittorrent.conf"
LOG_DIR="${DATA_PATH}/logs"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
CONSOLE_LOG="${DATA_PATH}/console.log"
PID_FILE=/var/run/qbittorrent.pid
PORT=8092
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
QBT_ID=84
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') qbittorrent/qbt_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. DOWNLOAD_DIR)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether qBittorrent is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The qbittorrent user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
qbt_ids() {
    awk -F: '$1 == "qbittorrent" { print $3 " " $4 }' /etc/passwd
}

# Makes a new web interface password (letters and digits), root's only.
#
# Prints nothing
new_password() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    # The page's session belonged to the old login
    rm -f "${DATA_PATH}/page_session"
    log 'generated a new web interface password'
}

# The downloads folder to start with: a Downloads share if the volume has one, else Public/Downloads.
#
# Prints it
default_download_dir() {
    if [ -d "${VOLUME_PATH}/Downloads" ]; then
        echo "${VOLUME_PATH}/Downloads"
    else
        echo "${VOLUME_PATH}/Public/Downloads"
    fi
}

setup() {
    local group download_dir

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^qbittorrent:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=qbittorrent
            grep -q '^qbittorrent:' /etc/group || addgroup -g ${QBT_ID} qbittorrent
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${QBT_ID} -G ${group} qbittorrent
    fi

    if [ -z "$(qbt_ids)" ]; then
        log "Could not create the qbittorrent user (is ID ${QBT_ID} already taken?)"

        return 1
    fi

    set -- $(qbt_ids)

    # Its own data (qBittorrent's profile and log) belongs to its user; the page's settings and the password to root
    mkdir -p "$(dirname "${CONF}")" "${LOG_DIR}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${PROFILE}" "${LOG_DIR}"
    chmod 700 "${PROFILE}" "${LOG_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'DOWNLOAD_DIR=%s\nLISTEN=all\nPEER_PORT=6882\nDOWN_LIMIT=0\nUP_LIMIT=0\n' "$(default_download_dir)" \
            > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password
    touch "${CONSOLE_LOG}"
    chmod 600 "${CONSOLE_LOG}"

    # The downloads folder (made the first time, in the share group, writable by it)
    download_dir="$(setting DOWNLOAD_DIR "$(default_download_dir)")"

    if [ ! -d "${download_dir}" ]; then
        log "creating the downloads folder: ${download_dir}"
        mkdir -p "${download_dir}" && chown "$1:$2" "${download_dir}" && chmod 2775 "${download_dir}"
    fi
}

# Writes the app's settings into qBittorrent's own qBittorrent.conf (while it's stopped: qBittorrent writes the file
# again when it stops), keeping everything else in it - e.g. what was changed in its web interface.
#
# Prints nothing; returns 1 if it couldn't be written
write_config() {
    set -- $(qbt_ids)

    # (PHP: the NAS always has it; the password is read from its file, not given on a command line)
    php "${APP_PATH}/lib/qbt.php" config "${CONF}" "${SETTINGS_FILE}" "${PASSWORD_FILE}" \
        "$(setting DOWNLOAD_DIR "$(default_download_dir)")" "${LOG_DIR}" || return 1

    chown "$1:$2" "${CONF}"
}

start() {
    if running; then
        log "qBittorrent is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    if ! write_config; then
        log 'Could not write its settings (is PHP working?)'

        return 1
    fi

    set -- $(qbt_ids)
    log "starting qBittorrent on port ${PORT} (log: ${LOG_DIR}/qbittorrent.log)"
    cd "${PROFILE}" || return 1
    # (its own list of certificate authorities, for HTTPS trackers, RSS feeds and searches)
    ( exec env HOME="${PROFILE}" SSL_CERT_FILE="${BIN}/ca-certificates.crt" "${BIN}/qbt_runas" "$1" "$2" \
        "${BIN}/qbittorrent-nox" --profile="${PROFILE}" --confirm-legal-notice ) >> "${CONSOLE_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "qBittorrent started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping qBittorrent (PID ${pid})"
        kill "${pid}"

        # It tells the trackers it's stopping and saves its torrents' progress first
        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${waited}" -ge 30 ]; then
                log 'qBittorrent did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Keeps its console log under 1MB (the previous part is kept as console.log.1); qBittorrent keeps its own log small.
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${CONSOLE_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${CONSOLE_LOG}" "${CONSOLE_LOG}.1" && : > "${CONSOLE_LOG}"
        chmod 600 "${CONSOLE_LOG}.1"
    fi
}

# The Nginx app finds qBittorrent by its folder and serves it at https://qbittorrent.<its domain>: rewrite its sites.
#
# Prints nothing
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart)
        stop
        start
        ;;
    new-password) new_password ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|daily|nginx" >&2

        exit 1
        ;;
esac
