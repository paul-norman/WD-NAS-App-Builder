#!/bin/sh
# Runs Miniflux (a minimalist feed reader: RSS, Atom and JSON Feed) as its own user, on port 8099. Its feeds, articles and
# settings are kept in the PostgreSQL app's server (a database and login of its own, made by the app: miniflux); its
# other data in the persistent path (Nas_Prog/_miniflux - kept across reinstalls). The Nginx app serves it at
# https://miniflux.<its domain> - by default (LISTEN=local, when the Nginx app is installed) only that way: it then
# listens on the NAS itself only (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:8099 on the local network.
# Its administrator (admin, with a password the app generates) is made on its first start:
#   miniflux_ctl.sh setup        - create its user, folders and settings (where missing)
#   miniflux_ctl.sh start        - start it (its database and login made first, once PostgreSQL answers - in the
#                                  background at boot), checking that it answers
#   miniflux_ctl.sh stop         - stop it
#   miniflux_ctl.sh restart      - stop, then start
#   miniflux_ctl.sh set-password - a new password for its administrator, read from the input (one line)
#   miniflux_ctl.sh backup       - back up its database (pg_dump, while it runs)
#   miniflux_ctl.sh daily        - the daily job: a backup, and keeping the log small
#   miniflux_ctl.sh nginx        - rewrite the Nginx app's sites (Miniflux's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_miniflux"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
# Its configuration (with its database's address and password) and its administrator's password for its first start:
# written at every start, root's, readable by its group
CONF_PATH="${DATA_PATH}/conf"
CONFIG_FILE="${CONF_PATH}/miniflux.conf"
SETTINGS_FILE="${DATA_PATH}/settings"
# Its administrator's password, its database login's password (both root's), and how setting the database up last went
PASSWORD_FILE="${DATA_PATH}/password"
DB_PASSWORD_FILE="${DATA_PATH}/db_password"
DB_STATUS="${DATA_PATH}/db.status"
MINIFLUX_LOG="${DATA_PATH}/miniflux.log"
PID_FILE=/var/run/miniflux.pid
PORT=8099
DB=miniflux
# Its own user and group (created if missing): the IDs used when creating them
MINIFLUX_ID=63
LOG=/tmp/debug_apkg

# The PostgreSQL app's server: its client and tools, its superuser's password (root's)
PG_BIN="${APPS_PATH}/postgresql/binaries/postgresql/bin"
PG_SUPERUSER_PASSWORD="${APPS_PATH}/_postgresql/postgres_password"
PG_SOCKET=/var/run/postgresql

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') miniflux/miniflux_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
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

# Whether Miniflux is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
mf_ids() {
    awk -F: '$1 == "miniflux" { print $3 " " $4 }' /etc/passwd
}

# Runs psql as PostgreSQL's postgres superuser (over its socket), with its password in the environment.
#
# $@ psql's arguments (the SQL on the input, or -c)
#
# Prints psql's output
psql_superuser() {
    PGPASSWORD="$(cat "${PG_SUPERUSER_PASSWORD}" 2>/dev/null)" "${PG_BIN}/psql" -h "${PG_SOCKET}" -U postgres \
        -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
}

# Runs psql as Miniflux's own login, in its database (over the socket), with its password in the environment.
#
# $@ psql's arguments (the SQL on the input, or -c)
#
# Prints psql's output
psql_miniflux() {
    PGPASSWORD="$(cat "${DB_PASSWORD_FILE}" 2>/dev/null)" "${PG_BIN}/psql" -h "${PG_SOCKET}" -U "${DB}" -d "${DB}" \
        -X -q -v ON_ERROR_STOP=1 "$@"
}

# Whether PostgreSQL answers the superuser.
#
# Returns 0 if it does
db_answering() {
    [ -x "${PG_BIN}/psql" ] && psql_superuser -c 'SELECT 1' > /dev/null 2>&1
}

# Notes how setting up the database went, for the page.
#
# $1 state   ok or failed
# $2 message Why it failed (none if ok)
db_status() {
    printf '%s %s %s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" > "${DB_STATUS}"
}

# Makes Miniflux's login and database in PostgreSQL (or gives the login a new password): the login owns the database,
# and can do nothing else. Waits for PostgreSQL to answer first.
#
# $1 wait Seconds to wait for PostgreSQL (default 0)
#
# Prints what happened; returns 0 once it's done
db_login() {
    local waited=0 password output

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            db_status failed 'PostgreSQL is not answering - is the PostgreSQL app installed and running?'
            log 'PostgreSQL is not answering - is the PostgreSQL app installed and running?'

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

    # A database can't be created in a transaction (DO blocks are one), so whether it exists is asked first
    if ! output="$(psql_superuser 2>&1 <<EOF
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB}') THEN
        CREATE ROLE ${DB};
    END IF;
END \$\$;
ALTER ROLE ${DB} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${password}';
EOF
)"; then
        db_status failed "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)"
        log "Could not set up its login in PostgreSQL: ${output}"

        return 1
    fi

    if [ "$(psql_superuser -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB}'" 2>/dev/null)" != 1 ]; then
        if ! output="$(psql_superuser -c "CREATE DATABASE ${DB} OWNER ${DB} ENCODING 'UTF8'" 2>&1)"; then
            db_status failed "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)"
            log "Could not create its database: ${output}"

            return 1
        fi

        log "created its database in PostgreSQL: ${DB}"
    fi

    ( umask 077; printf '%s' "${password}" > "${DB_PASSWORD_FILE}.tmp" ) \
        && mv -f "${DB_PASSWORD_FILE}.tmp" "${DB_PASSWORD_FILE}" || return 1
    db_status ok ''
    log 'its database login is set up'
}

setup() {
    local listen

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^miniflux:' /etc/group || addgroup -g ${MINIFLUX_ID} miniflux
    grep -q '^miniflux:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${MINIFLUX_ID} -G miniflux miniflux

    if [ -z "$(mf_ids)" ]; then
        log "Could not create the miniflux user (are ID ${MINIFLUX_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(mf_ids)

    # Its folder: root's (settings, passwords, backups), passable for Miniflux; its configuration readable by its group
    mkdir -p "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_DIR=\nBACKUP_KEEP=7\nPRIVATE_FEEDS=off\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}" )

    # Its log: its user's (Miniflux writes it itself)
    touch "${MINIFLUX_LOG}"
    chown "$1:$2" "${MINIFLUX_LOG}"
    chmod 600 "${MINIFLUX_LOG}"
}

# Its address for links and its cookies: the Nginx app's site if it has one, else the NAS's on port 8099.
#
# Prints it
base_url() {
    local url

    url="$(php -r 'require $argv[1]; echo manage_nginx_site($argv[2], "http://127.0.0.1:" . $argv[3])["url"];' \
        "${APP_PATH}/manage/manage_helpers.php" "${APPS_PATH}" "${PORT}" 2>/dev/null)"

    if [ -z "${url}" ]; then
        url="http://$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1):${PORT}/"
    fi

    echo "${url}"
}

# Writes Miniflux's configuration: its port and address, its database (PostgreSQL always listens on 127.0.0.1 too; its
# own login), its address for links, the Nginx app as a proxy it trusts (visitors' own addresses), its administrator
# (made on its first start from the app's password - an existing one is left as it is), feeds on the local network only
# if the page allows them, and a lighter load than its defaults (the NAS's processor and memory are shared with
# everything else).
#
# Returns 0 once it's written
write_config() {
    local host=127.0.0.1

    set -- $(mf_ids)
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0

    ( umask 027; cat > "${CONFIG_FILE}.tmp" <<EOF
# Written by the Miniflux app at every start (miniflux_ctl.sh) - changes here are lost
LISTEN_ADDR=${host}:${PORT}
BASE_URL=$(base_url)
DATABASE_URL=postgres://${DB}:$(cat "${DB_PASSWORD_FILE}")@127.0.0.1:5432/${DB}?sslmode=disable
DATABASE_MAX_CONNS=5
RUN_MIGRATIONS=1
CREATE_ADMIN=1
ADMIN_USERNAME=admin
ADMIN_PASSWORD_FILE=${CONF_PATH}/admin_password
TRUSTED_REVERSE_PROXY_NETWORKS=127.0.0.1/32
WORKER_POOL_SIZE=4
FETCHER_ALLOW_PRIVATE_NETWORKS=$([ "$(setting PRIVATE_FEEDS off)" = on ] && echo 1 || echo 0)
LOG_FILE=${MINIFLUX_LOG}
LOG_LEVEL=info
EOF
    ) && chown "root:$2" "${CONFIG_FILE}.tmp" && chmod 640 "${CONFIG_FILE}.tmp" \
        && mv -f "${CONFIG_FILE}.tmp" "${CONFIG_FILE}" || return 1

    # (its password file for its first start: its group may read it)
    cp "${PASSWORD_FILE}" "${CONF_PATH}/admin_password.tmp" && chown "root:$2" "${CONF_PATH}/admin_password.tmp" \
        && chmod 640 "${CONF_PATH}/admin_password.tmp" && mv -f "${CONF_PATH}/admin_password.tmp" "${CONF_PATH}/admin_password"
}

# Whether Miniflux answers (its health check), while it's still running - not something else on the port.
#
# $1 wait Seconds to wait (its first start sets its database up)
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt "$1" ]; do
        running || return 1
        [ "$(curl -s -m 3 "http://127.0.0.1:${PORT}/healthcheck" 2>/dev/null)" = OK ] && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Gives its administrator a password (from the input), hashed as Miniflux hashes them (bcrypt), in its database: in use
# at once.
#
# Returns 0 once it's set
admin_password() {
    local password hash php output

    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    # The NAS's php, wherever it's called from - e.g. the page, with a short PATH (both PHP 7.4 and 8.5 have bcrypt).
    # PHP writes bcrypt as $2y$, the same as Go's $2a$
    php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
    hash="$(printf '%s' "${password}" \
        | "${php:-php}" -n -r 'echo "\$2a" . substr(password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT), 3);')"

    case "${hash}" in
        '$2a$'*) ;;
        *) log 'Could not hash the password (is PHP working?)'; return 1 ;;
    esac

    # (a bcrypt hash has no quotes: only letters, digits, . / and $)
    if ! output="$(psql_miniflux -tA -c "UPDATE users SET password = '${hash}' WHERE username = 'admin' RETURNING id" 2>&1)" \
        || [ -z "${output}" ]; then
        log "Could not set its administrator's password: ${output:-there's no admin user}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

start() {
    if running; then
        log "Miniflux is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    # Its database and login: made the first time - at boot, PostgreSQL may start after this app, so it's waited for in
    # the background, then Miniflux started
    if [ ! -s "${DB_PASSWORD_FILE}" ] && ! db_login 10; then
        log 'waiting for PostgreSQL in the background, to set up its database'
        ( sh "${APP_PATH}/miniflux_ctl.sh" later > /dev/null 2>&1 & )

        return 0
    fi

    write_config || return 1
    set -- $(mf_ids)

    log "starting Miniflux on port ${PORT} (log: ${MINIFLUX_LOG})"
    cd "${CONF_PATH}" || return 1
    ( exec env -i PATH=/usr/bin:/bin HOME=/nonexistent "${BIN}/miniflux_runas" "$1" "$2" "${BIN}/miniflux" \
        -c "${CONFIG_FILE}" ) >> "${MINIFLUX_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up 120; then
        log "Miniflux did not start (see ${MINIFLUX_LOG}): $(tail -n 3 "${MINIFLUX_LOG}" 2>/dev/null | tr '\n' ' ' \
            | cut -c1-400)"

        return 1
    fi

    log "Miniflux started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Miniflux (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Miniflux did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Backs up its database (everything Miniflux keeps: feeds, articles, users and settings) with PostgreSQL's pg_dump, as
# its own login - a consistent copy while it runs - into the backup folder, keeping the newest ones. Restored with
# pg_restore (see the app's README).
#
# Returns 0 once it's written
backup() {
    local dir keep file output old

    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -s "${DB_PASSWORD_FILE}" ]; then
        log 'Nothing to back up yet (its database has not been set up)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    file="${dir}/miniflux-$(date '+%Y%m%d-%H%M%S').dump"

    if ! output="$( ( umask 077; PGPASSWORD="$(cat "${DB_PASSWORD_FILE}")" "${PG_BIN}/pg_dump" -h "${PG_SOCKET}" \
        -U "${DB}" -d "${DB}" -Fc -f "${file}.tmp" ) 2>&1)" || ! mv -f "${file}.tmp" "${file}"; then
        log "The backup failed: ${output}"
        rm -f "${file}.tmp"

        return 1
    fi

    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/miniflux-*.dump 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps Miniflux's log under 1MB (the previous part is kept as miniflux.log.1).
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${MINIFLUX_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${MINIFLUX_LOG}" "${MINIFLUX_LOG}.1" && : > "${MINIFLUX_LOG}"
        chmod 600 "${MINIFLUX_LOG}.1"
    fi
}

# The Nginx app finds Miniflux by its folder (its nginx.json): rewrite its sites.
#
# Prints nothing
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx" php

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
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
    later)
        # (Started by start: waits up to 5 minutes for PostgreSQL, then starts Miniflux)
        db_login 300 && start
        ;;
    set-password) admin_password ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
