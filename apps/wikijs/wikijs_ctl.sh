#!/bin/sh
# Runs Wiki.js (a wiki: pages written together - live - in Markdown or a visual editor) as its own user, with its own
# Node.js, on port 3010. Its pages, files and settings are kept in the PostgreSQL app's server (a database and login of
# its own, made by the app: wikijs); its other data in the persistent path (Nas_Prog/_wikijs - kept across reinstalls).
# The Nginx app serves it at https://wikijs.<its domain> - by default (LISTEN=local, when the Nginx app is installed)
# only that way: it then listens on the NAS itself only (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:3010
# on the local network. Its administrator (admin@nas.local, with a password the app generates) is made on its first
# start:
#   wikijs_ctl.sh setup        - create its user, folders and settings (where missing)
#   wikijs_ctl.sh start        - start it (its database and login made first, once PostgreSQL answers - in the
#                                background at boot), checking that it answers
#   wikijs_ctl.sh stop         - stop it
#   wikijs_ctl.sh restart      - stop, then start
#   wikijs_ctl.sh set-password - a new password for its administrator, read from the input (one line)
#   wikijs_ctl.sh backup       - back up its database (pg_dump, while it runs)
#   wikijs_ctl.sh daily        - the daily job: a backup, and keeping the log small
#   wikijs_ctl.sh nginx        - rewrite the Nginx app's sites (Wiki.js's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_wikijs"
BIN="${APP_PATH}/binaries"
WIKI="${BIN}/wiki"
# Wiki.js's own data (its cache, uploads on their way in): its user's
WIKI_DATA="${DATA_PATH}/data"
# Its configuration (with its database password): written at every start, root's, readable by its group
CONF_PATH="${DATA_PATH}/conf"
CONFIG_FILE="${CONF_PATH}/config.yml"
SETTINGS_FILE="${DATA_PATH}/settings"
# Its administrator's password, and its ID in Wiki.js (to give it a new password, whatever its email address becomes)
PASSWORD_FILE="${DATA_PATH}/password"
ADMIN_ID_FILE="${DATA_PATH}/admin_id"
# Its database login's password (root's), and how setting the database up last went (for the page)
DB_PASSWORD_FILE="${DATA_PATH}/db_password"
DB_STATUS="${DATA_PATH}/db.status"
WIKI_LOG="${DATA_PATH}/wikijs.log"
PID_FILE=/var/run/wikijs.pid
PORT=3010
ADMIN_EMAIL=admin@nas.local
# Its database and login in PostgreSQL
DB=wikijs
# Its own user and group (created if missing): the IDs used when creating them
WIKI_ID=95
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') wikijs/wikijs_ctl.sh $*" >> ${LOG}
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

# Whether Wiki.js is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
wiki_ids() {
    awk -F: '$1 == "wikijs" { print $3 " " $4 }' /etc/passwd
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

# Runs psql as Wiki.js's own login, in its database (over the socket), with its password in the environment.
#
# $@ psql's arguments (the SQL on the input, or -c)
#
# Prints psql's output
psql_wiki() {
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

# Makes Wiki.js's login and database in PostgreSQL (or gives the login a new password): the login owns the database,
# so Wiki.js can add the extensions it needs to it itself (ltree and pg_trgm - trusted extensions), and nothing else.
# Waits for PostgreSQL to answer first.
#
# $1 wait Seconds to wait for PostgreSQL (default 0)
#
# Prints what happened; returns 0 once it's done
db_login() {
    waited=0

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
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^wikijs:' /etc/group || addgroup -g ${WIKI_ID} wikijs
    grep -q '^wikijs:' /etc/passwd || adduser -D -H -h "${WIKI_DATA}" -s /bin/false -u ${WIKI_ID} -G wikijs wikijs

    if [ -z "$(wiki_ids)" ]; then
        log "Could not create the wikijs user (are ID ${WIKI_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(wiki_ids)

    # Its folder: root's (settings, passwords, backups), passable for Wiki.js; its configuration readable by its group;
    # its own data its user's
    mkdir -p "${WIKI_DATA}" "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"
    chown -R "$1:$2" "${WIKI_DATA}"
    chmod 700 "${WIKI_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_DIR=\nBACKUP_KEEP=7\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${WIKI_LOG}"
    chmod 600 "${WIKI_LOG}"
}

# Writes Wiki.js's configuration: its port and address, its database (PostgreSQL always listens on 127.0.0.1 too; its
# own login), its data folder, and two background workers (the NAS's processor is shared with everything else).
#
# Returns 0 once it's written
write_config() {
    set -- $(wiki_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0

    ( umask 027; cat > "${CONFIG_FILE}.tmp" <<EOF
# Written by the Wiki.js app at every start (wikijs_ctl.sh) - changes here are lost
port: ${PORT}
bindIP: ${host}
db:
  host: 127.0.0.1
  port: 5432
  user: '${DB}'
  pass: '$(cat "${DB_PASSWORD_FILE}")'
  db: '${DB}'
  schema: wiki
  ssl: false
logLevel: info
logFormat: default
offline: false
dataPath: '${WIKI_DATA}'
scheduler:
  workers: 2
EOF
    ) && chown "root:$2" "${CONFIG_FILE}.tmp" && chmod 640 "${CONFIG_FILE}.tmp" \
        && mv -f "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
}

# Whether Wiki.js answers (its readiness check), while it's still running - not something else on the port.
#
# $1 wait Seconds to wait (its first start sets its database up: it can take a few minutes)
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt "$1" ]; do
        running || return 1
        code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/_ready" 2>/dev/null)"
        [ "${code}" = 200 ] && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# Gives its administrator a password (from the input), hashed as Wiki.js hashes them (bcrypt), in its database: in use
# at once. Its first start makes it with this password already; this keeps the page's copy right whatever happened
# since (e.g. a database kept from an earlier install).
#
# Returns 0 once it's set
admin_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    # The NAS's php, wherever it's called from - e.g. the page, with a short PATH (both PHP 7.4 and 8.5 have bcrypt)
    php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
    hash="$(printf '%s' "${password}" \
        | "${php:-php}" -n -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT, ["cost" => 12]);')"

    case "${hash}" in
        '$2y$12$'*) ;;
        *) log 'Could not hash the password (is PHP working?)'; return 1 ;;
    esac

    # Its administrator: the one the app made (by its ID, saved the first time - whatever its email address is now)
    id="$(cat "${ADMIN_ID_FILE}" 2>/dev/null)"

    if [ -z "${id}" ]; then
        id="$(psql_wiki -tA -c "SELECT id FROM wiki.users WHERE email = '${ADMIN_EMAIL}'" 2>/dev/null | head -n 1)"

        case "${id}" in
            *[!0-9a-f-]*|'') log "Its administrator (${ADMIN_EMAIL}) wasn't found in its database"; return 1 ;;
        esac

        ( umask 077; printf '%s\n' "${id}" > "${ADMIN_ID_FILE}" )
    fi

    # Its password is kept under the key of Wiki.js's own (local) login - whichever entry of its logins has one. A
    # bcrypt hash has no quotes (only letters, digits, . / and $) and the ID was checked, so both go in the SQL as they
    # are
    if ! output="$(psql_wiki -tA 2>&1 <<EOF
UPDATE wiki.users u
SET auth = jsonb_set(jsonb_set(u.auth, ARRAY[k.key, 'password'], to_jsonb('${hash}'::text)),
    ARRAY[k.key, 'mustChangePwd'], 'false'::jsonb)
FROM (SELECT key FROM wiki.users, jsonb_each(auth) WHERE id = '${id}' AND value ? 'password' LIMIT 1) k
WHERE u.id = '${id}'
RETURNING u.id;
EOF
)" || [ -z "${output}" ]; then
        log "Could not set its administrator's password: ${output:-its administrator has no Wiki.js login of its own}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

start() {
    if running; then
        log "Wiki.js is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    # Its database and login: made the first time - at boot, PostgreSQL may start after this app, so it's waited for in
    # the background, then Wiki.js started
    if [ ! -s "${DB_PASSWORD_FILE}" ] && ! db_login 10; then
        log 'waiting for PostgreSQL in the background, to set up its database'
        ( sh "${APP_PATH}/wikijs_ctl.sh" later > /dev/null 2>&1 & )

        return 0
    fi

    write_config || return 1
    set -- $(wiki_ids)
    first=''

    # Its first start makes its administrator: the password is given in its environment (not on a command line)
    if [ ! -s "${PASSWORD_FILE}" ]; then
        first="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    fi

    log "starting Wiki.js on port ${PORT} (log: ${WIKI_LOG})"
    cd "${WIKI}" || return 1
    ( export CONFIG_FILE NODE_ENV=production HOME="${WIKI_DATA}" PATH="/usr/sbin:/usr/bin:/sbin:/bin"
        [ -n "${first}" ] && export ADMIN_EMAIL ADMIN_PASS="${first}"
        exec "${BIN}/wikijs_runas" "$1" "$2" "${BIN}/node" --no-experimental-webstorage backend ) \
        >> "${WIKI_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up 300; then
        log "Wiki.js did not start (see ${WIKI_LOG}): $(tail -n 3 "${WIKI_LOG}" 2>/dev/null | tr '\n' ' ' \
            | cut -c1-400)"

        return 1
    fi

    if [ -n "${first}" ]; then
        printf '%s\n' "${first}" | admin_password || return 1
        log "its administrator is ${ADMIN_EMAIL} (its password is shown on the app's page)"
    fi

    log "Wiki.js started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Wiki.js (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Wiki.js did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Backs up its database (everything Wiki.js keeps: pages, their history, files, users and settings) with PostgreSQL's
# pg_dump, as its own login - a consistent copy while it runs - into the backup folder, keeping the newest ones.
# Restored with pg_restore (see the app's README).
#
# Returns 0 once it's written
backup() {
    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -s "${DB_PASSWORD_FILE}" ]; then
        log 'Nothing to back up yet (its database has not been set up)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    file="${dir}/wikijs-$(date '+%Y%m%d-%H%M%S').dump"

    if ! output="$( ( umask 077; PGPASSWORD="$(cat "${DB_PASSWORD_FILE}")" "${PG_BIN}/pg_dump" -h "${PG_SOCKET}" \
        -U "${DB}" -d "${DB}" -Fc -f "${file}.tmp" ) 2>&1)" || ! mv -f "${file}.tmp" "${file}"; then
        log "The backup failed: ${output}"
        rm -f "${file}.tmp"

        return 1
    fi

    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/wikijs-*.dump 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps Wiki.js's log under 1MB (the previous part is kept as wikijs.log.1)
rotate_log() {
    if [ "$(wc -c < "${WIKI_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${WIKI_LOG}" "${WIKI_LOG}.1" && : > "${WIKI_LOG}"
        chmod 600 "${WIKI_LOG}.1"
    fi
}

# The Nginx app finds Wiki.js by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

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
    restart) stop; start ;;
    later)
        # (Started by start: waits up to 5 minutes for PostgreSQL, then starts Wiki.js)
        db_login 300 && start
        ;;
    set-password) admin_password ;;
    backup) backup ;;
    daily) backup; rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
