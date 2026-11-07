#!/bin/sh
# Runs the template app's program as its own user - the template's example is miniserve, sharing a folder in a web
# browser (Nas_Prog/_template/www). The Nginx app serves it at https://template.<its domain> - by default
# (LISTEN=local, when the Nginx app is installed) only that way: it then listens on the NAS itself only (127.0.0.1).
# With LISTEN=all it's also at http://<nas-ip>:8090 on the local network. Its data is in the persistent path
# (Nas_Prog/_template - kept across reinstalls):
#   template_ctl.sh setup   - create its user, folders and settings (where missing)
#   template_ctl.sh start   - start it (on port 8090), checking that it's answering
#   template_ctl.sh stop    - stop it
#   template_ctl.sh restart - stop, then start
#   template_ctl.sh nginx   - rewrite the Nginx app's sites (its own comes from its nginx.json), and reload it
#   template_ctl.sh daily   - keep its log small
#
# A new app: copy this as <app>_ctl.sh, replace "template" (and "Template") with the app's name, pick its port and its
# own user's ID (unused by the other apps: see theirs), and change start() to run its program

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_template"
BIN="${APP_PATH}/binaries"
WWW_PATH="${DATA_PATH}/www"
SETTINGS_FILE="${DATA_PATH}/settings"
APP_LOG="${DATA_PATH}/template.log"
PID_FILE=/var/run/template.pid
PORT=8090
# Its own user and group (created if missing): the IDs used when creating them
TEMPLATE_ID=62
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') template/template_ctl.sh $*" >> ${LOG}
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

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them (e.g. 62 62), or nothing if there's no such user
template_ids() {
    awk -F: '$1 == "template" { print $3 " " $4 }' /etc/passwd
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders and its settings.
#
# Returns 0 once done
setup() {
    grep -q '^template:' /etc/group || addgroup -g ${TEMPLATE_ID} template
    grep -q '^template:' /etc/passwd \
        || adduser -D -H -h "${DATA_PATH}" -s /bin/false -u ${TEMPLATE_ID} -G template template

    if [ -z "$(template_ids)" ]; then
        log "Could not create the template user (are ID ${TEMPLATE_ID}'s user or group already taken?)"

        return 1
    fi

    # Its folder and settings: root's. The folder it shares: root's too, readable by its user (it only reads it)
    mkdir -p "${WWW_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 755 "${DATA_PATH}"

    if [ ! -f "${WWW_PATH}/index.html" ]; then
        log "creating its example page: ${WWW_PATH}/index.html"
        printf '<!doctype html>\n<title>Template</title>\n<h1>The template app works</h1>\n<p>This page is %s.</p>\n' \
            "${WWW_PATH}/index.html" > "${WWW_PATH}/index.html"
    fi

    chmod -R a+rX "${WWW_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${APP_LOG}"
    chmod 600 "${APP_LOG}"
}

# Waits (up to 20 seconds) for it to answer, while it's still running - not something else on the port.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 20 ]; do
        running || return 1
        curl -s -m 2 -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Starts it as its own user, in the background (its output in its log), on the NAS itself or on every address.
#
# Returns 0 once it answers
start() {
    if running; then
        log "Template is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    set -- $(template_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting Template on ${host}:${PORT}"
    cd "${DATA_PATH}" || return 1
    ( HOME="${DATA_PATH}" exec "${BIN}/template_runas" "$1" "$2" "${BIN}/miniserve" \
        --interfaces ${host} --port ${PORT} --index index.html --no-symlinks --title Template "${WWW_PATH}" ) \
        >> "${APP_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Template did not start (see ${APP_LOG}): $(tail -n 2 "${APP_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Template started with PID: $(cat ${PID_FILE})"
}

# Stops it: politely first, then (after 10 seconds) by force.
#
# Returns 0 once stopped
stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Template (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 10 ]; then
                kill -9 "${pid}" 2>/dev/null
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Its site in the Nginx app: the Nginx app finds it by its folder (its nginx.json), so rewrite its sites and reload it.
#
# Returns 0 (with or without the Nginx app)
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
            && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its log under 1MB (the previous part is kept as template.log.1).
#
# Returns 0
rotate_log() {
    if [ "$(wc -c < "${APP_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${APP_LOG}" "${APP_LOG}.1" && : > "${APP_LOG}"
        chmod 600 "${APP_LOG}.1"
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
    nginx) nginx_site ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|nginx|daily" >&2

        exit 1
        ;;
esac
