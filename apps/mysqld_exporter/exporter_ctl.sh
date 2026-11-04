#!/bin/sh
# Runs mysqld_exporter (MariaDB's metrics for Prometheus) as its own user, on the NAS itself only
# (http://127.0.0.1:9104/metrics), with a login of its own to the NAS's MariaDB (WD's own, or the MariaDB app's):
# mysqld_exporter@localhost, which can read MariaDB's status, not your data, created by the app with a password only it
# keeps.
# Prometheus and Grafana (their apps, when installed) are told about its scrape job (prometheus/) and dashboard
# (dashboards/). Its data is in the persistent path (Nas_Prog/_mysqld_exporter - kept across reinstalls):
#   exporter_ctl.sh setup       - create its user and folder (where missing)
#   exporter_ctl.sh start       - start it, setting up its login first (once MariaDB answers - in the background at boot)
#   exporter_ctl.sh stop        - stop it
#   exporter_ctl.sh restart     - stop, then start
#   exporter_ctl.sh login       - set up its login again (a new password), then restart it
#   exporter_ctl.sh monitoring [--without]
#                               - tell the Prometheus and Grafana apps (--without: it's being removed)
#   exporter_ctl.sh daily       - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
APP_NAME=mysqld_exporter
DATA_PATH="${APPS_PATH}/_${APP_NAME}"
BIN="${APP_PATH}/binaries"
# Its password (root's), the exporter's own copy of what it needs to log in, and how setting it up last went (for the
# page)
PASSWORD_FILE="${DATA_PATH}/password"
CREDENTIALS="${DATA_PATH}/credentials"
LOGIN_STATUS="${DATA_PATH}/login.status"
EXP_LOG="${DATA_PATH}/${APP_NAME}.log"
PID_FILE="/var/run/${APP_NAME}.pid"
PORT=9104
# Its own user and group (created if missing): the IDs used when creating them
EXP_ID=90
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

# The NAS's MariaDB (WD's own, or the MariaDB app's - the same socket): root logs in over it without a password
SOCKET=/var/lib/mysql/mysql.sock
# Its login in MariaDB
DB_USER=mysqld_exporter

# Runs MariaDB's client as root (over the socket): the MariaDB app's, else the NAS's own.
#
# $@ The client's arguments (the SQL on the input, or -e)
#
# Prints its output
mysql_root() {
    client="${APPS_PATH}/mariadb/binaries/mariadb/bin/mariadb"
    [ -x "${client}" ] || client="$(PATH="/usr/bin:/bin:/usr/local/bin:/usr/local/modules/mysql/bin:${PATH}" command -v mysql)"
    "${client:-mysql}" --socket="${SOCKET}" -uroot "$@"
}

# Whether MariaDB answers root.
#
# Returns 0 if it does
db_answering() {
    mysql_root -N -e 'SELECT 1' > /dev/null 2>&1
}

# Creates its login in MariaDB (or gives it the new password): only from the NAS itself, at most 3 connections, with
# what it needs to read MariaDB's status (PROCESS, REPLICATION CLIENT, and performance_schema) - not your data.
#
# $1 password The password
#
# Prints MariaDB's errors; returns 0 once it's done
db_create_login() {
    mysql_root <<EOF 2>&1
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '$1' WITH MAX_USER_CONNECTIONS 3;
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '$1' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT ON *.* TO '${DB_USER}'@'localhost';
GRANT SELECT ON performance_schema.* TO '${DB_USER}'@'localhost';
EOF
}

# The exporter's own my.cnf: its login and the socket (its own user's).
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
#
# Returns 0 once it's written
write_credentials() {
    printf '[client]\nuser=%s\npassword=%s\nsocket=%s\n' "${DB_USER}" "$(cat "${PASSWORD_FILE}")" "${SOCKET}" \
        > "${CREDENTIALS}.tmp" && chown "$1:$2" "${CREDENTIALS}.tmp" && chmod 600 "${CREDENTIALS}.tmp" \
        && mv -f "${CREDENTIALS}.tmp" "${CREDENTIALS}"
}

# Runs the exporter (in the background, its output appended to its log), as its own user.
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
run_exporter() {
    ( cd "${DATA_PATH}" && exec "${BIN}/${APP_NAME}_runas" "$1" "$2" "${BIN}/${APP_NAME}" \
        --config.my-cnf="${CREDENTIALS}" --collect.info_schema.processlist --web.listen-address="127.0.0.1:${PORT}" \
        --log.level=warn ) >> "${EXP_LOG}" 2>&1 &
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

# Sets up the exporter's login (see db_create_login) and its copy of it, waiting for MariaDB to answer.
# How it went goes in login.status, for the page.
#
# $1 wait Seconds to wait for MariaDB (default 0)
#
# Prints what happened; returns 0 once it's set up
login() {
    waited=0

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            printf 'failed %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "MariaDB is not answering as root on its socket - is it running?" > "${LOGIN_STATUS}"
            log "MariaDB is not answering as root on its socket - is it running?"

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"

    if ! output="$(db_create_login "${password}")"; then
        printf 'failed %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)" \
            > "${LOGIN_STATUS}"
        log "Could not set up its login: ${output}"

        return 1
    fi

    ( umask 077; printf '%s' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}" \
        || return 1
    set -- $(exp_ids)
    write_credentials "$1" "$2" || return 1
    printf 'ok %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${LOGIN_STATUS}"
    log 'its login is set up'
}

start() {
    if running; then
        log "${APP_NAME} is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    # Its login: set up the first time - at boot, MariaDB may start after this app, so it's waited for in the
    # background (the exporter answers meanwhile - with an empty password, which it needs to start - saying MariaDB
    # is down), then the exporter restarted with it
    if [ ! -s "${PASSWORD_FILE}" ] && ! login 10; then
        log 'waiting for MariaDB in the background, to set up its login'
        ( sh "${APP_PATH}/exporter_ctl.sh" later > /dev/null 2>&1 & )
        ( umask 077; : > "${PASSWORD_FILE}" )
        set -- $(exp_ids)
        write_credentials "$1" "$2"
    elif [ ! -s "${CREDENTIALS}" ]; then
        set -- $(exp_ids)
        write_credentials "$1" "$2"
    fi

    set -- $(exp_ids)
    log "starting ${APP_NAME} on 127.0.0.1:${PORT}"
    run_exporter "$1" "$2"
    echo $! > "${PID_FILE}"
    waited=0

    # Answering (its own metrics) while still running - not something else on the port
    until curl -s -m 2 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^mysql_up '; do
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
    later)
        # (Started by start: waits up to 5 minutes for MariaDB, then restarts the exporter with its login)
        login 300 && stop && start
        ;;
    monitoring) monitoring "${2:-}" ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|login|monitoring [--without]|daily" >&2

        exit 1
        ;;
esac
