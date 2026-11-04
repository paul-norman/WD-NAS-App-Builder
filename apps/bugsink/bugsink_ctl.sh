#!/bin/sh
# Runs Bugsink (error tracking: it collects the errors your own programs and websites report, through Sentry's SDKs) as
# its own user: its web server (gunicorn, on port 8000) and its background worker (snappea), with its data in the
# persistent path (Nas_Prog/_bugsink - kept across reinstalls). The Nginx app serves it at https://bugsink.<its domain>
# - by default (LISTEN=local, when the Nginx app is installed) only that way: it then listens on the NAS itself only
# (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:8000 on the local network. Its admin user (admin, with a
# password the app generates) is made on its first start:
#   bugsink_ctl.sh setup        - create its user, folders and settings (where missing)
#   bugsink_ctl.sh start        - write its settings, update its databases, then start it (checking it answers)
#   bugsink_ctl.sh stop         - stop it
#   bugsink_ctl.sh restart      - stop, then start
#   bugsink_ctl.sh set-password - a new password for its admin user, read from the input (one line)
#   bugsink_ctl.sh nginx        - rewrite the Nginx app's sites (Bugsink's comes from its nginx.json), and reload it
#   bugsink_ctl.sh daily        - keep its log small
#
# Its settings (conf/bugsink_conf.py) are written by the app at every start (lib/bugsink.php): its address follows the
# Nginx app's site for it, so a restart picks up a changed one

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_bugsink"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
# Bugsink's own data (its databases, its worker's wake-up calls, events being taken in): its user's
BUGSINK_DATA="${DATA_PATH}/data"
# Its settings module: root's, readable by its group
CONF_PATH="${DATA_PATH}/conf"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
BUGSINK_LOG="${DATA_PATH}/bugsink.log"
PID_FILE=/var/run/bugsink.pid
SNAPPEA_PID_FILE=/var/run/bugsink-snappea.pid
PORT=8000
# Its admin user's name
ADMIN=admin
# Its own user and group (created if missing): the IDs used when creating them
BUGSINK_ID=92
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') bugsink/bugsink_ctl.sh $*" >> ${LOG}
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

# Whether a process (its PID file's) is running.
#
# $1 pid_file The PID file
#
# Returns 0 if it is
running() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
bugsink_ids() {
    awk -F: '$1 == "bugsink" { print $3 " " $4 }' /etc/passwd
}

# Runs one of Bugsink's management commands (Django's manage.py), as its own user, with its settings.
#
# $@ The command and its arguments (e.g. migrate --noinput)
#
# Prints its output
manage() {
    set -- $(bugsink_ids) "$@"
    uid="$1"
    gid="$2"
    shift 2
    ( cd "${CONF_PATH}" && HOME="${BUGSINK_DATA}" PYTHONPATH="${CONF_PATH}" DJANGO_SETTINGS_MODULE=bugsink_conf \
        exec "${BIN}/bugsink_runas" "${uid}" "${gid}" "${PYTHON}" -m bugsink.scripts.manage "$@" )
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^bugsink:' /etc/group || addgroup -g ${BUGSINK_ID} bugsink
    grep -q '^bugsink:' /etc/passwd || adduser -D -H -h "${BUGSINK_DATA}" -s /bin/false -u ${BUGSINK_ID} -G bugsink bugsink

    if [ -z "$(bugsink_ids)" ]; then
        log "Could not create the bugsink user (are ID ${BUGSINK_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(bugsink_ids)

    # Its folder: root's (settings, password, secret key), passable for Bugsink; its settings module readable by its
    # group; its own data its user's (Bugsink refuses folders whose parents aren't root's or its own)
    mkdir -p "${BUGSINK_DATA}" "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"
    chown -R "$1:$2" "${BUGSINK_DATA}"
    chmod 700 "${BUGSINK_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${BUGSINK_LOG}"
    chmod 600 "${BUGSINK_LOG}"
}

# Writes Bugsink's settings module (lib/bugsink.php): its address, hosts, databases and folders.
#
# Returns 0 once it's written
write_conf() {
    set -- $(bugsink_ids)
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
    php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"

    "${php:-php}" "${APP_PATH}/lib/bugsink.php" conf "${APPS_PATH}" "$(setting LISTEN local)" "${ip:-127.0.0.1}" \
        "$(hostname)" || return 1
    chown "root:$2" "${CONF_PATH}/bugsink_conf.py"
    chmod 640 "${CONF_PATH}/bugsink_conf.py"
}

# Sets the admin user's password (Django hashes it), from the input - creating the user if it's missing.
#
# Returns 0 once it's set
admin_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    # Given in the command's environment, not on its command line (which other programs on the NAS can read) - exported
    # in a subshell: BusyBox's sh doesn't pass a VAR=value given before a function on to the programs it runs
    if ! output="$(export BUGSINK_NEW_PASSWORD="${password}"; manage shell -c "
import os
from django.contrib.auth import get_user_model
User = get_user_model()
user = User.objects.filter(username='${ADMIN}').first() or User(username='${ADMIN}', email='${ADMIN}@nas.invalid')
user.is_staff = user.is_superuser = user.is_active = True
user.set_password(os.environ['BUGSINK_NEW_PASSWORD'])
user.save()" 2>&1)"; then
        log "Could not set the admin user's password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

# Whether it's Bugsink answering (its login page), while its web server is still running - not something else on the
# port.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 60 ]; do
        running "${PID_FILE}" || return 1
        curl -s -m 3 "http://127.0.0.1:${PORT}/accounts/login/" 2>/dev/null | grep -q 'Bugsink' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running "${PID_FILE}" && running "${SNAPPEA_PID_FILE}"; then
        log "Bugsink is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    stop
    setup || return 1
    write_conf || return 1

    # Its databases created or brought up to date (after an update), then its admin user the first time
    if ! output="$(manage migrate --noinput 2>&1 && manage migrate snappea --database=snappea --noinput 2>&1)"; then
        log "Could not update Bugsink's databases: $(echo "${output}" | tail -n 5)"

        return 1
    fi

    if [ ! -s "${PASSWORD_FILE}" ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | admin_password || return 1
        log "created its admin user: ${ADMIN} (its password is shown on the app's page)"
    fi

    set -- $(bugsink_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting Bugsink on ${host}:${PORT}"
    cd "${CONF_PATH}" || return 1
    ( HOME="${BUGSINK_DATA}" PYTHONPATH="${CONF_PATH}" DJANGO_SETTINGS_MODULE=bugsink_conf \
        exec "${BIN}/bugsink_runas" "$1" "$2" "${PYTHON}" -m gunicorn --bind "${host}:${PORT}" --workers 2 \
        --no-control-socket --forwarded-allow-ips 127.0.0.1 bugsink.wsgi ) >> "${BUGSINK_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    ( HOME="${BUGSINK_DATA}" PYTHONPATH="${CONF_PATH}" DJANGO_SETTINGS_MODULE=bugsink_conf \
        exec "${BIN}/bugsink_runas" "$1" "$2" "${PYTHON}" -m bugsink.scripts.runsnappea ) >> "${BUGSINK_LOG}" 2>&1 &
    echo $! > "${SNAPPEA_PID_FILE}"

    if ! wait_up; then
        log "Bugsink did not start (see ${BUGSINK_LOG}): $(tail -n 2 "${BUGSINK_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Bugsink started with PID: $(cat ${PID_FILE}) (its worker: $(cat ${SNAPPEA_PID_FILE}))"
}

# Stops a process (its PID file's), letting it finish its work first (up to 30 seconds).
#
# $1 pid_file The PID file
stop_process() {
    if running "$1"; then
        pid="$(cat "$1")"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "$1"
}

stop() {
    if running "${PID_FILE}" || running "${SNAPPEA_PID_FILE}"; then
        log 'stopping Bugsink (its web server and worker)'
    fi

    stop_process "${PID_FILE}"
    stop_process "${SNAPPEA_PID_FILE}"
}

# The Nginx app finds Bugsink by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its log under 1MB (the previous part is kept as bugsink.log.1)
rotate_log() {
    if [ "$(wc -c < "${BUGSINK_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${BUGSINK_LOG}" "${BUGSINK_LOG}.1" && : > "${BUGSINK_LOG}"
        chmod 600 "${BUGSINK_LOG}.1"
    fi
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    set-password) setup && write_conf && admin_password ;;
    nginx) nginx_site ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|nginx|daily" >&2

        exit 1
        ;;
esac
