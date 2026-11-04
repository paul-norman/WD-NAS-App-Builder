#!/bin/sh
# Runs redis_exporter (Valkey's metrics for Prometheus) as its own user, on the NAS itself only
# (http://127.0.0.1:9121/metrics), with the Valkey app's password (Valkey has one password: it's read again at every
# start, so a changed one is picked up by restarting the exporter).
# Prometheus and Grafana (their apps, when installed) are told about its scrape job (prometheus/) and dashboard
# (dashboards/). Its data is in the persistent path (Nas_Prog/_redis_exporter - kept across reinstalls):
#   exporter_ctl.sh setup       - create its user and folder (where missing)
#   exporter_ctl.sh start       - start it, setting up its password first (Valkey's)
#   exporter_ctl.sh stop        - stop it
#   exporter_ctl.sh restart     - stop, then start
#   exporter_ctl.sh login       - set up its password again (read Valkey's again), then restart it
#   exporter_ctl.sh monitoring [--without]
#                               - tell the Prometheus and Grafana apps (--without: it's being removed)
#   exporter_ctl.sh daily       - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
APP_NAME=redis_exporter
DATA_PATH="${APPS_PATH}/_${APP_NAME}"
BIN="${APP_PATH}/binaries"
# Its password (root's), the exporter's own copy of what it needs to log in, and how setting it up last went (for the
# page)
PASSWORD_FILE="${DATA_PATH}/password"
CREDENTIALS="${DATA_PATH}/credentials"
LOGIN_STATUS="${DATA_PATH}/login.status"
EXP_LOG="${DATA_PATH}/${APP_NAME}.log"
PID_FILE="/var/run/${APP_NAME}.pid"
PORT=9121
# Its own user and group (created if missing): the IDs used when creating them
EXP_ID=91
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${APP_NAME}/exporter_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# Whether the exporter is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The exporter user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
exp_ids() {
    awk -F: -v user="${APP_NAME}" '$1 == user { print $3 " " $4 }' /etc/passwd
}

# The Valkey app's server, and its configuration (root's), which holds its password (requirepass)
VALKEY_CONF="${APPS_PATH}/_valkey/valkey.conf"

# Whether the Valkey app's password can be read.
#
# Returns 0 if it can
db_answering() {
    [ -n "$(valkey_password)" ]
}

# The Valkey app's password (from its configuration).
#
# Prints it
valkey_password() {
    sed -n 's/^requirepass[[:space:]]*//p' "${VALKEY_CONF}" 2>/dev/null | head -n 1 | tr -d '"\r'
}

# Takes the Valkey app's password (Valkey has a single password: no login of its own is made).
#
# $1 password Unused
#
# Prints an error; returns 0 once it's done
db_create_login() {
    if [ -z "$(valkey_password)" ]; then
        echo "No password in ${VALKEY_CONF}"

        return 1
    fi

    ( umask 077; valkey_password > "${PASSWORD_FILE}" )
}

# Nothing: the exporter gets the password in its environment at start (see run_exporter), not from a file of its own.
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
#
# Returns 0
write_credentials() {
    return 0
}

# Runs the exporter (in the background, its output appended to its log), as its own user - the password in its
# environment (which only root and its own user can read), not on its command line (which every program on the NAS
# can read).
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
run_exporter() {
    ( cd "${DATA_PATH}" && REDIS_PASSWORD="$(cat "${PASSWORD_FILE}")" exec "${BIN}/${APP_NAME}_runas" "$1" "$2" \
        "${BIN}/${APP_NAME}" -redis.addr redis://127.0.0.1:6379 -web.listen-address "127.0.0.1:${PORT}" \
        -log-level warn ) >> "${EXP_LOG}" 2>&1 &
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q "^${APP_NAME}:" /etc/group || addgroup -g ${EXP_ID} "${APP_NAME}"
    grep -q "^${APP_NAME}:" /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${EXP_ID} -G "${APP_NAME}" "${APP_NAME}"

    if [ -z "$(exp_ids)" ]; then
        log "Could not create the ${APP_NAME} user (are ID ${EXP_ID}'s user or group already taken?)"

        return 1
    fi

    # Root's folder, passable for the exporter (to read its own files)
    mkdir -p "${DATA_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    touch "${EXP_LOG}"
    chmod 600 "${EXP_LOG}"
}

# Sets up the exporter's password (see db_create_login) and its copy of it, waiting for Valkey to answer.
# How it went goes in login.status, for the page.
#
# $1 wait Seconds to wait for Valkey (default 0)
#
# Prints what happened; returns 0 once it's set up
login() {
    waited=0

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            printf 'failed %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "The Valkey app's password could not be read - is the Valkey app installed?" > "${LOGIN_STATUS}"
            log "The Valkey app's password could not be read - is the Valkey app installed?"

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"

    if ! output="$(db_create_login "${password}")"; then
        printf 'failed %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)" \
            > "${LOGIN_STATUS}"
        log "Could not set up its password: ${output}"

        return 1
    fi

    chmod 600 "${PASSWORD_FILE}"
    set -- $(exp_ids)
    write_credentials "$1" "$2" || return 1
    printf 'ok %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${LOGIN_STATUS}"
    log 'its password is set up'
}

start() {
    if running; then
        log "${APP_NAME} is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    # The Valkey app's password, read again at every start (a changed one is picked up by restarting the exporter)
    login 0 || log "Valkey's password could not be read: the exporter will say Valkey is down"

    set -- $(exp_ids)
    log "starting ${APP_NAME} on 127.0.0.1:${PORT}"
    run_exporter "$1" "$2"
    echo $! > "${PID_FILE}"
    waited=0

    # Answering (its own metrics) while still running - not something else on the port
    until curl -s -m 2 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^redis_up '; do
        if ! running || [ ${waited} -ge 20 ]; then
            log "${APP_NAME} did not start (see ${EXP_LOG}): $(tail -n 2 "${EXP_LOG}" 2>/dev/null | tr '\n' ' ')"

            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done

    log "${APP_NAME} started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping ${APP_NAME} (PID ${pid})"
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

# Tells the Prometheus and Grafana apps (when installed) about its scrape job and dashboard: Prometheus reloads, Grafana
# gathers the apps' dashboards again.
#
# $1 without --without when the exporter is being removed (its files are still there), else nothing
#
# Prints nothing; returns 0
monitoring() {
    without=''
    [ "${1:-}" = '--without' ] && without="--without ${APP_NAME}"

    if [ -f "${APPS_PATH}/prometheus/prom_ctl.sh" ]; then
        sh "${APPS_PATH}/prometheus/prom_ctl.sh" reload ${without} >> ${LOG} 2>&1
    fi

    if [ -f "${APPS_PATH}/grafana/graf_ctl.sh" ]; then
        sh "${APPS_PATH}/grafana/graf_ctl.sh" dashboards ${without} >> ${LOG} 2>&1
    fi

    return 0
}

# Keeps the exporter's log under 1MB (the previous part is kept as <app>.log.1)
rotate_log() {
    if [ "$(wc -c < "${EXP_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${EXP_LOG}" "${EXP_LOG}.1" && : > "${EXP_LOG}"
        chmod 600 "${EXP_LOG}.1"
    fi
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    login)
        setup && login 120 && stop && start
        ;;
    monitoring) monitoring "${2:-}" ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|login|monitoring [--without]|daily" >&2

        exit 1
        ;;
esac
