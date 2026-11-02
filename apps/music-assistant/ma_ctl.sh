#!/bin/sh
# Runs Music Assistant as its own user, with its data in the persistent path (Nas_Prog/_music-assistant - kept across
# reinstalls):
#   ma_ctl.sh setup          - create its user and folders (where missing)
#   ma_ctl.sh start          - start it (web interface on port 8095). The first time, the app also creates its admin user
#   ma_ctl.sh stop           - stop Music Assistant
#   ma_ctl.sh restart        - stop, then start
#   ma_ctl.sh new-password   - give the admin user a new (generated) password, while it runs
#   ma_ctl.sh backup         - back up its settings, library and users (stopping it for a moment, if it runs)
#   ma_ctl.sh daily          - the daily job: a backup, and keeping the log small
#   ma_ctl.sh nginx          - add / update Music Assistant's site in the Nginx app (and reload it)
#
# It runs straight on the NAS's network, so it finds the players (e.g. Sonos) by itself, and they fetch the music from
# it. It only reads music folders added in its settings: its user needs to be able to read them (shares normally are)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_music-assistant"
# PHP updates the Nginx app's sites: wherever it is, also when run with a minimal PATH, e.g. from the management page
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
# The certificate authorities its Python trusts (certifi's, bundled): it looks in /etc/ssl by default, where the NAS has
# none it can use - so no HTTPS connection could be checked (streaming services, radio, servers on the NAS's own domain)
CA_FILE="${BIN}/python/lib/python3.14/site-packages/certifi/cacert.pem"
MA_DATA="${DATA_PATH}/data"
BACKUP_DIR="${DATA_PATH}/backups"
MA_LOG="${DATA_PATH}/console.log"
PID_FILE=/var/run/music-assistant.pid
PORT=8095
# Its own user and group (created if missing): the IDs used when creating them
MA_ID=79
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') music-assistant/ma_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# Whether the app's process is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
ma_ids() {
    awk -F: '$1 == "musicassistant" { print $3 " " $4 }' /etc/passwd
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^musicassistant:' /etc/group || addgroup -g ${MA_ID} musicassistant
    grep -q '^musicassistant:' /etc/passwd || adduser -D -H -h "${MA_DATA}" -s /bin/false -u ${MA_ID} -G musicassistant musicassistant

    if [ -z "$(ma_ids)" ]; then
        log "Could not create the musicassistant user (are ID ${MA_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(ma_ids)

    # Its data (settings, library, cache, temporary files) belongs to its user; the backups, admin password, page token
    # and log to root
    mkdir -p "${MA_DATA}/tmp" "${BACKUP_DIR}"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${MA_DATA}" "${MA_DATA}/tmp"
    chmod 700 "${MA_DATA}" "${BACKUP_DIR}"
    touch "${MA_LOG}"
    chmod 600 "${MA_LOG}"
}

start() {
    if running; then
        log "Music Assistant is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    set -- $(ma_ids)
    log "starting Music Assistant on port ${PORT} (log: ${MA_DATA}/musicassistant.log)"
    # Its own Python, ffmpeg, uv and Deno come first on its PATH; its temporary files go next to its data, not to /tmp
    # (in the NAS's RAM). Its output is appended to (so that it can be cut short while it runs)
    cd "${MA_DATA}" || return 1
    ( exec env -i HOME="${MA_DATA}" PATH="${BIN}:${BIN}/python/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${MA_DATA}/tmp" \
        LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 URLLIB3_NO_OVERRIDE=1 SSL_CERT_FILE="${CA_FILE}" \
        "${BIN}/ma_runas" "$1" "$2" "${PYTHON}" -m music_assistant --data-dir "${MA_DATA}" --cache-dir "${MA_DATA}/.cache" \
        --log-level info ) >> "${MA_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Music Assistant started with PID: $(cat ${PID_FILE})"

    # The first time, the app creates the admin user itself (before anyone else on the network can)
    if [ ! -s "${DATA_PATH}/admin_password" ]; then
        "${PYTHON}" -I "${APP_PATH}/lib/ma_api.py" setup "${DATA_PATH}" >> ${LOG} 2>&1 \
            || log "Could not create the admin user (see ${LOG})"
    fi
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Music Assistant (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Music Assistant did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

new_password() {
    "${PYTHON}" -I "${APP_PATH}/lib/ma_api.py" new-password "${DATA_PATH}"
}

backup() {
    if [ ! -d "${MA_DATA}" ] || [ -z "$(ls "${MA_DATA}"/*.db 2>/dev/null)" ]; then
        log 'Nothing to back up yet (start Music Assistant first)'

        return 1
    fi

    # Music Assistant keeps its databases locked while it runs (SQLite's exclusive locking mode), so nothing else can
    # read them: it's stopped for the copy (a few seconds), then started again
    was_running=0

    if running; then
        was_running=1
        stop > /dev/null
    fi

    output="$("${PYTHON}" -I "${APP_PATH}/lib/ma_backup.py" "${MA_DATA}" "${BACKUP_DIR}" 7 2>&1)"
    status=$?

    log "${output}"
    [ ${was_running} = 1 ] && start > /dev/null

    return ${status}
}

# Keeps the app's copy of Music Assistant's output under 1MB (the previous part is kept as console.log.1). Music
# Assistant keeps its own log, musicassistant.log, small by itself
rotate_log() {
    if [ "$(wc -c < "${MA_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${MA_LOG}" "${MA_LOG}.1" && : > "${MA_LOG}"
        chmod 600 "${MA_LOG}.1"
    fi
}

# The Nginx app finds Music Assistant by its folder and serves it at https://music.<its domain>: rewrite its
# sites
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
    backup) backup ;;
    daily) backup; rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
