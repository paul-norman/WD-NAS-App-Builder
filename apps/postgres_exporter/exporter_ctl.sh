#!/bin/sh
# Runs postgres_exporter (PostgreSQL's metrics for Prometheus) as its own user, on the NAS itself only
# (http://127.0.0.1:9187/metrics), with a login of its own to the PostgreSQL app's server: postgres_exporter, a member of
# pg_monitor (it reads PostgreSQL's statistics, not your data), created by the app with a password only it keeps.
# Prometheus and Grafana (their apps, when installed) are told about its scrape job (prometheus/) and dashboard
# (dashboards/). Its data is in the persistent path (Nas_Prog/_postgres_exporter - kept across reinstalls):
#   exporter_ctl.sh setup       - create its user and folder (where missing)
#   exporter_ctl.sh start       - start it, setting up its login first (once PostgreSQL answers - in the background at boot)
#   exporter_ctl.sh stop        - stop it
#   exporter_ctl.sh restart     - stop, then start
#   exporter_ctl.sh login       - set up its login again (a new password), then restart it
#   exporter_ctl.sh monitoring [--without]
#                               - tell the Prometheus and Grafana apps (--without: it's being removed)
#   exporter_ctl.sh daily       - keep its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
APP_NAME=postgres_exporter
DATA_PATH="${APPS_PATH}/_${APP_NAME}"
BIN="${APP_PATH}/binaries"
# Its password (root's), the exporter's own copy of what it needs to log in, and how setting it up last went (for the
# page)
PASSWORD_FILE="${DATA_PATH}/password"
CREDENTIALS="${DATA_PATH}/credentials"
LOGIN_STATUS="${DATA_PATH}/login.status"
EXP_LOG="${DATA_PATH}/${APP_NAME}.log"
PID_FILE="/var/run/${APP_NAME}.pid"
PORT=9187
# Its own user and group (created if missing): the IDs used when creating them
EXP_ID=89
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

# The PostgreSQL app's server: its client, its superuser's password (root's) - the exporter connects over TCP, as
# PostgreSQL always listens on 127.0.0.1 too
PG_BIN="${APPS_PATH}/postgresql/binaries/postgresql/bin"
PG_SUPERUSER_PASSWORD="${APPS_PATH}/_postgresql/postgres_password"
# Its login in PostgreSQL
ROLE=postgres_exporter

# Runs psql as PostgreSQL's postgres superuser (over its socket), with its password in the environment.
#
# $@ psql's arguments (the SQL on the input, or -c)
#
# Prints psql's output
psql_superuser() {
    PGPASSWORD="$(cat "${PG_SUPERUSER_PASSWORD}" 2>/dev/null)" "${PG_BIN}/psql" -h /var/run/postgresql -U postgres \
        -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
}

# Whether PostgreSQL answers the superuser.
#
# Returns 0 if it does
db_answering() {
    [ -x "${PG_BIN}/psql" ] && psql_superuser -c 'SELECT 1' > /dev/null 2>&1
}

# Creates its login in PostgreSQL (or gives it the new password): a member of pg_monitor - it can read PostgreSQL's
# statistics, not your data - with at most 3 connections.
#
# $1 password The password
#
# Prints PostgreSQL's errors; returns 0 once it's done
db_create_login() {
    psql_superuser <<EOF 2>&1
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ROLE}') THEN
        CREATE ROLE ${ROLE};
    END IF;
END \$\$;
ALTER ROLE ${ROLE} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 3 PASSWORD '$1';
GRANT pg_monitor TO ${ROLE};
EOF
}

# The exporter's copy of its password (its own user's, read through DATA_SOURCE_PASS_FILE).
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
#
# Returns 0 once it's written
write_credentials() {
    cp "${PASSWORD_FILE}" "${CREDENTIALS}.tmp" && chown "$1:$2" "${CREDENTIALS}.tmp" && chmod 600 "${CREDENTIALS}.tmp" \
        && mv -f "${CREDENTIALS}.tmp" "${CREDENTIALS}"
}

# Runs the exporter (in the background, its output appended to its log), as its own user.
#
# $1 uid The exporter's user ID
# $2 gid Its group ID
run_exporter() {
    # An empty configuration file: without one, it warns at every start
    [ -f "${DATA_PATH}/postgres_exporter.yml" ] || echo '{}' > "${DATA_PATH}/postgres_exporter.yml"
    chmod 644 "${DATA_PATH}/postgres_exporter.yml"
    ( cd "${DATA_PATH}" && DATA_SOURCE_URI='127.0.0.1:5432/postgres?sslmode=disable' DATA_SOURCE_USER="${ROLE}" \
        DATA_SOURCE_PASS_FILE="${CREDENTIALS}" exec "${BIN}/${APP_NAME}_runas" "$1" "$2" "${BIN}/${APP_NAME}" \
        --config.file="${DATA_PATH}/postgres_exporter.yml" --web.listen-address="127.0.0.1:${PORT}" \
        --collector.stat_checkpointer --log.level=warn ) >> "${EXP_LOG}" 2>&1 &
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

# Sets up the exporter's login (see db_create_login) and its copy of it, waiting for PostgreSQL to answer.
# How it went goes in login.status, for the page.
#
# $1 wait Seconds to wait for PostgreSQL (default 0)
#
# Prints what happened; returns 0 once it's set up
login() {
    waited=0

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            printf 'failed %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "PostgreSQL is not answering - is the PostgreSQL app installed and running?" > "${LOGIN_STATUS}"
            log "PostgreSQL is not answering - is the PostgreSQL app installed and running?"

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

    # Its login: set up the first time - at boot, PostgreSQL may start after this app, so it's waited for in the
    # background (the exporter answers meanwhile - with an empty password, which it needs to start - saying PostgreSQL
    # is down), then the exporter restarted with it
    if [ ! -s "${PASSWORD_FILE}" ] && ! login 10; then
        log 'waiting for PostgreSQL in the background, to set up its login'
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
    until curl -s -m 2 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^pg_up '; do
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
        # (Started by start: waits up to 5 minutes for PostgreSQL, then restarts the exporter with its login)
        login 300 && stop && start
        ;;
    monitoring) monitoring "${2:-}" ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|login|monitoring [--without]|daily" >&2

        exit 1
        ;;
esac
