#!/bin/sh
# Runs Kopia's server (its web interface, and the snapshots it schedules) as root - it backs up and restores any file on
# the NAS - with its configuration in the persistent path (Nas_Prog/_kopia - kept across reinstalls):
#   kopia_ctl.sh setup          - create the folders, settings and the web interface's password (where missing)
#   kopia_ctl.sh start          - start the server (on port 51515: the NAS itself only, for the Nginx app, or the network)
#   kopia_ctl.sh stop           - stop the server (a snapshot in progress is resumed next time)
#   kopia_ctl.sh restart        - stop, then start
#   kopia_ctl.sh new-password   - generate a new password for the web interface (applied when the server next starts)
#   kopia_ctl.sh daily          - the daily job: keeping its output log small
#   kopia_ctl.sh nginx          - add / update Kopia's site in the Nginx app (and reload it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_kopia"
KOPIA="${APP_PATH}/binaries/kopia"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/server_password"
KOPIA_OUT="${DATA_PATH}/kopia.log"
PID_FILE=/var/run/kopia.pid
PORT=51515
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') kopia/kopia_ctl.sh $*" >> ${LOG}
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

new_password() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    log 'generated a new password for the web interface'
}

setup() {
    # Everything here is root's: the repository's configuration holds its password and the storage's credentials
    mkdir -p "${DATA_PATH}/logs" "${DATA_PATH}/cache"
    chmod 700 "${DATA_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Kopia can read and restore any file on the NAS: with the Nginx app installed, only reachable through HTTPS
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password
    touch "${KOPIA_OUT}"
    chmod 600 "${KOPIA_OUT}"
}

start() {
    if running; then
        log "Kopia is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    host=0.0.0.0
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1
    log "starting Kopia's server on ${host}:${PORT} (output: ${KOPIA_OUT})"
    # The web interface's password is given in the environment (never on the command line, which other processes can
    # see); plain HTTP (--insecure) - HTTPS comes from the Nginx app. Kopia's own update checks are off (the app shows a
    # NAS alert for new releases), and its GRPC server (for other Kopia clients) too
    cd "${DATA_PATH}" || return 1
    ( exec env HOME="${DATA_PATH}" KOPIA_CONFIG_PATH="${DATA_PATH}/repository.config" KOPIA_LOG_DIR="${DATA_PATH}/logs" \
        KOPIA_CACHE_DIRECTORY="${DATA_PATH}/cache" KOPIA_SERVER_USERNAME=admin KOPIA_SERVER_PASSWORD="$(cat "${PASSWORD_FILE}")" \
        "${KOPIA}" server start --ui --insecure --address="http://${host}:${PORT}" --no-grpc --no-check-for-updates \
        --ui-preferences-file="${DATA_PATH}/ui-preferences.json" ) >> "${KOPIA_OUT}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Kopia started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Kopia (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Kopia did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Keeps the server's output log under 1MB (the previous part is kept as kopia.log.1 - Kopia's own logs, in logs/, are
# rotated by Kopia)
rotate_log() {
    if [ "$(wc -c < "${KOPIA_OUT}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${KOPIA_OUT}" "${KOPIA_OUT}.1" && : > "${KOPIA_OUT}"
        chmod 600 "${KOPIA_OUT}.1"
    fi
}

# The Nginx app finds Kopia by its folder and serves it at https://kopia.<its domain>: rewrite its sites
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
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|daily|nginx" >&2

        exit 1
        ;;
esac
