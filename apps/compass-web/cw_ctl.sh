#!/bin/sh
# Runs Compass Web (MongoDB Compass in the browser: browse, query, edit and import / export documents, indexes, schema
# and aggregations) as its own user, on port 8087, connected to the MongoDB app's server as its administrator (the
# password read from the MongoDB app at every start). It asks for its own login (admin, with a password the app
# generates) before anything. The Nginx app serves it at https://compass.<its domain> - by default (LISTEN=local, when
# the Nginx app is installed) only that way: it then listens on the NAS itself only (127.0.0.1). With LISTEN=all it's
# also at http://<nas-ip>:8087 on the local network. Its data is in the persistent path (Nas_Prog/_compass-web):
#   cw_ctl.sh setup        - create its user, folders, settings and password (where missing)
#   cw_ctl.sh start        - start it (checking it answers)
#   cw_ctl.sh stop         - stop it
#   cw_ctl.sh restart      - stop, then start
#   cw_ctl.sh set-password - a new password for its login, read from the input (one line): in use after a restart
#   cw_ctl.sh nginx        - rewrite the Nginx app's sites (Compass Web's comes from its nginx.json), and reload it
#   cw_ctl.sh daily        - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_compass-web"
BIN="${APP_PATH}/binaries"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
# Its own folder (its HOME: nothing much is kept there - its connections are given at every start)
HOME_PATH="${DATA_PATH}/home"
CW_LOG="${DATA_PATH}/compass-web.log"
PID_FILE=/var/run/compass-web.pid
PORT=8087
USERNAME=admin
# The MongoDB app's server and its administrator's password (root's)
MONGO_PORT=27017
MONGO_PASSWORD_FILE="${APPS_PATH}/_mongodb/password"
# Its own user and group (created if missing): the IDs used when creating them
CW_ID=66
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') compass-web/cw_ctl.sh $*" >> ${LOG}
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

# Whether Compass Web is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
cw_ids() {
    awk -F: '$1 == "compassweb" { print $3 " " $4 }' /etc/passwd
}

# Writes its login's password (from the input).
#
# Returns 0 once it's written
set_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^compassweb:' /etc/group || addgroup -g ${CW_ID} compassweb
    grep -q '^compassweb:' /etc/passwd \
        || adduser -D -H -h "${HOME_PATH}" -s /bin/false -u ${CW_ID} -G compassweb compassweb

    if [ -z "$(cw_ids)" ]; then
        log "Could not create the compassweb user (are ID ${CW_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(cw_ids)

    # Its folder: root's (settings, password), passable for Compass Web; its home its own
    mkdir -p "${HOME_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${HOME_PATH}"
    chmod 700 "${HOME_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    if [ ! -s "${PASSWORD_FILE}" ]; then
        log 'generating the password for its login (shown on the app'"'"'s page)'
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | set_password || return 1
    fi

    touch "${CW_LOG}"
    chmod 600 "${CW_LOG}"
}

# Whether it's Compass Web answering (its health check, which needs no login), while it's still running.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 60 ]; do
        running || return 1
        code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz" 2>/dev/null)"
        [ "${code}" = 200 ] && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running; then
        log "Compass Web is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    if [ ! -s "${MONGO_PASSWORD_FILE}" ]; then
        log 'The MongoDB app has not been set up (Compass Web connects to it): install and start it first'

        return 1
    fi

    set -- $(cw_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting Compass Web on ${host}:${PORT}"
    cd "${BIN}/compass-web" || return 1
    # Its settings in its environment (CW_...), not on its command line, which other programs can read: the MongoDB
    # app's server as its administrator (a generated password: letters and digits, nothing to encode), its own login;
    # no editing of connections, no shell (it runs JavaScript on the NAS), no AI features
    ( export CW_MONGO_URI="mongodb://admin:$(cat "${MONGO_PASSWORD_FILE}")@127.0.0.1:${MONGO_PORT}/?authSource=admin" \
        CW_BASIC_AUTH_USERNAME="${USERNAME}" CW_BASIC_AUTH_PASSWORD="$(cat "${PASSWORD_FILE}")" CW_PORT="${PORT}" \
        CW_HOST="${host}" CW_APP_NAME='Compass Web' HOME="${HOME_PATH}" NODE_ENV=production
        exec "${BIN}/cw_runas" "$1" "$2" "${BIN}/node" node_modules/compass-web/dist/server.js ) >> "${CW_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Compass Web did not start (see ${CW_LOG}): $(tail -n 3 "${CW_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Compass Web started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Compass Web (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 15 ]; then
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# The Nginx app finds Compass Web by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its log under 1MB (the previous part is kept as compass-web.log.1)
rotate_log() {
    if [ "$(wc -c < "${CW_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${CW_LOG}" "${CW_LOG}.1" && : > "${CW_LOG}"
        chmod 600 "${CW_LOG}.1"
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
