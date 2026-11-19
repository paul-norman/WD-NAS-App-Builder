#!/bin/sh
# Runs changedetection.io (watches web pages for changes) as its own user, with its data in the persistent path
# (Nas_Prog/_changedetection - kept across reinstalls). The Nginx app serves it at https://changes.<its domain> - by
# default (LISTEN=local, when the Nginx app is installed) only that way: it then listens on the NAS itself only
# (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:5000 on the local network. Its login password is the app's
# (made at the first setup, shown and changed on the app's page):
#   changedetection_ctl.sh setup          - create its user, folders, settings and password (where missing)
#   changedetection_ctl.sh start          - start it (on port 5000), checking that it's changedetection.io answering
#   changedetection_ctl.sh stop           - stop it
#   changedetection_ctl.sh restart        - stop, then start
#   changedetection_ctl.sh password       - a new login password: the one on its input (one line), or a generated one
#                                           if none - then a restart
#   changedetection_ctl.sh browser on     - use the Browser recipe's Chrome on this NAS (run by the recipe's hooks),
#                                           then a restart
#   changedetection_ctl.sh browser off    - no browser (as the recipe's removal has it), then a restart
#   changedetection_ctl.sh browser <url>  - use a browser elsewhere (its DevTools address), then a restart
#   changedetection_ctl.sh nginx          - rewrite the Nginx app's sites (its own comes from its nginx.json), and
#                                           reload it
#   changedetection_ctl.sh daily          - keep its log small
#
# With a browser, changedetection.io's "Chrome" fetcher loads pages in it (for pages built by JavaScript, browser steps,
# screenshots and the visual selector) through Patchright - see static/changedetection. Without one, every page is
# fetched with plain HTTP requests.

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_changedetection"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
# changedetection.io's own data (its user's): settings, watches and their history
DATASTORE="${DATA_PATH}/datastore"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
OUT_LOG="${DATA_PATH}/changedetection.out"
PID_FILE=/var/run/changedetection.pid
PORT=5000
# The Browser recipe's Chrome (its DevTools port, on the NAS itself)
LOCAL_BROWSER=http://127.0.0.1:9222
# Its own user and group (created if missing): the IDs used when creating them
CHANGEDETECTION_ID=51
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') changedetection/changedetection_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page and this script).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Changes a setting in the app's settings file (keeping the others).
#
# $1 name  The setting
# $2 value Its new value (may be empty)
#
# Returns 0 once saved
set_setting() {
    { grep -v "^$1=" "${SETTINGS_FILE}" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "${SETTINGS_FILE}.tmp" \
        && chmod 600 "${SETTINGS_FILE}.tmp" && mv -f "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
}

# Whether changedetection.io is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
changedetection_ids() {
    awk -F: '$1 == "changedetection" { print $3 " " $4 }' /etc/passwd
}

# Writes a new password (letters and digits) to a file only root can read.
#
# $1 file The file
#
# Returns 0 once written
new_password_file() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "$1" )
}

setup() {
    local listen

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^changedetection:' /etc/group || addgroup -g ${CHANGEDETECTION_ID} changedetection
    grep -q '^changedetection:' /etc/passwd \
        || adduser -D -H -h "${DATASTORE}" -s /bin/false -u ${CHANGEDETECTION_ID} -G changedetection changedetection

    if [ -z "$(changedetection_ids)" ]; then
        log "Could not create the changedetection user (are ID ${CHANGEDETECTION_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(changedetection_ids)

    # Its folder: root's (settings, password), passable for changedetection.io; its datastore its user's
    mkdir -p "${DATASTORE}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${DATASTORE}"
    chmod 700 "${DATASTORE}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBROWSER_URL=\nLOCAL_ADDRESSES=0\nNTFY_TOPIC=\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # Its login password (the page shows it): root's only - changedetection.io gets it hashed
    if [ ! -s "${PASSWORD_FILE}" ]; then
        new_password_file "${PASSWORD_FILE}"
        log 'created its login password (shown on the app page)'
    fi

    chmod 600 "${PASSWORD_FILE}"
    touch "${OUT_LOG}"
    chmod 600 "${OUT_LOG}"
}

# The Nginx app's address for changedetection.io (its site's, whatever it was renamed to), if it has one.
#
# Prints it (e.g. https://changes.example.com/), or nothing
site_url() {
    local php

    [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ] || return 0

    php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
    "${php:-php}" -r 'require $argv[1];
        $settings = sites_load($argv[2]);
        foreach ($settings["apps"] as $app) {
            if ($app["enabled"] && $settings["domain"] !== "" && rtrim($app["target"], "/") === $argv[3]) {
                echo "https://", sites_host($settings, $app), "/";
                break;
            }
        }' "${APPS_PATH}/nginx/lib/sites.php" "${APPS_PATH}/_nginx" "http://127.0.0.1:${PORT}" 2>/dev/null
}

# The ntfy app's address for the topic set on the page (Apprise's form, with the token the ntfy app keeps for the
# apps), if a topic is set and the ntfy app is installed.
#
# Prints it, or nothing
ntfy_url() {
    local topic token

    topic="$(setting NTFY_TOPIC '')"
    token="$(cat "${APPS_PATH}/_ntfy/token" 2>/dev/null)"

    if [ -n "${topic}" ] && [ -n "${token}" ] && [ -d "${APPS_PATH}/ntfy" ]; then
        printf 'ntfy://%s@127.0.0.1:2586/%s' "${token}" "${topic}"
    fi
}

# Whether it's changedetection.io answering (its login page), while it's still running - not something else on the
# port.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 180 ]; do
        running || return 1
        curl -s -m 3 "http://127.0.0.1:${PORT}/login" 2>/dev/null | grep -qi 'type="password"' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    local host=127.0.0.1
    local salted browser base_url

    if running; then
        log "changedetection.io is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    salted="$("${PYTHON}" "${APP_PATH}/lib/settings.py" salted "${PASSWORD_FILE}")" || {
        log 'its password could not be read'

        return 1
    }

    # Its alerts to the ntfy app's topic (if set): in changedetection.io's own settings, while it's stopped
    "${PYTHON}" "${APP_PATH}/lib/settings.py" notify "${DATASTORE}/changedetection.json" "$(ntfy_url)" \
        || log 'its ntfy alert address could not be set'

    browser="$(setting BROWSER_URL '')"
    base_url="$(site_url)"
    set -- $(changedetection_ids)
    log "starting changedetection.io on port ${PORT} (LISTEN=$(setting LISTEN local), browser: ${browser:-none})"
    cd "${DATASTORE}" || return 1
    # (exported: the run-as helper passes its environment on)
    export HOME="${DATASTORE}" SALTED_PASS="${salted}" LOGGER_LEVEL=WARNING FETCH_WORKERS=4
    # Pages on the local network (a router's, a printer's...): only when allowed on the page
    [ "$(setting LOCAL_ADDRESSES 0)" = 1 ] && export ALLOW_IANA_RESTRICTED_ADDRESSES=true
    # Links in its alerts: the Nginx app's address, if it has one
    [ -n "${base_url}" ] && export BASE_URL="${base_url}"
    [ -n "${browser}" ] && export PLAYWRIGHT_DRIVER_URL="${browser}"
    ( exec "${BIN}/changedetection_runas" "$1" "$2" "${PYTHON}" -c \
        'import changedetectionio; changedetectionio.main()' -d "${DATASTORE}" -h "${host}" -p "${PORT}" ) \
        >> "${OUT_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "changedetection.io did not start (see ${OUT_LOG}): $(tail -n 2 "${OUT_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "changedetection.io started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping changedetection.io (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'changedetection.io did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# A new login password - the one on the input (its first line), or a generated one if it's empty - then a restart.
#
# Returns 0 once changedetection.io runs with it
new_password() {
    local typed

    setup || return 1
    IFS= read -r typed || true

    if [ -n "${typed}" ]; then
        ( umask 077; printf '%s\n' "${typed}" > "${PASSWORD_FILE}.tmp" )
        mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    else
        new_password_file "${PASSWORD_FILE}"
    fi

    log 'its login password was changed'
    stop
    start
}

# Sets the browser it uses, then restarts it.
#
# $1 which on (the Browser recipe's, on this NAS), off (none), or a browser's DevTools address (http:// or ws://)
#
# Returns 0 once changedetection.io runs with it
browser() {
    local url

    case "$1" in
        on) url="${LOCAL_BROWSER}" ;;
        off) url='' ;;
        http://*|https://*|ws://*|wss://*) url="$1" ;;
        *)
            echo 'Usage: changedetection_ctl.sh browser on|off|<its DevTools address>' >&2

            return 1
            ;;
    esac

    setup || return 1
    set_setting BROWSER_URL "${url}" || return 1
    log "its browser is now: ${url:-none}"
    stop
    start
}

# The Nginx app finds changedetection.io by its folder (its nginx.json): rewrite its sites
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"
    local php

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
            && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its output log under 1MB.
#
# Returns 0
rotate_log() {
    if [ "$(wc -c < "${OUT_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${OUT_LOG}" "${OUT_LOG}.1" && : > "${OUT_LOG}"
        chmod 600 "${OUT_LOG}.1"
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
    password) new_password ;;
    browser) browser "$2" ;;
    nginx) nginx_site ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|password|browser on|off|<url>|nginx|daily" >&2

        exit 1
        ;;
esac
