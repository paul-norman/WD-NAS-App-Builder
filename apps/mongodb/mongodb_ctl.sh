#!/bin/sh
# Runs MongoDB (a document database) as its own user, with its data in the persistent path (Nas_Prog/_mongodb - kept
# across reinstalls), on port 27017 - logins always required. By default (LISTEN=local) only programs on the NAS itself
# reach it (127.0.0.1, e.g. the Compass Web app); with LISTEN=all, the local network too. Its administrator (admin,
# with a password the app generates) is made on its first start:
#   mongodb_ctl.sh setup          - create its user, folders and settings (where missing)
#   mongodb_ctl.sh start          - write its configuration, start MongoDB (checking it answers), and make its
#                                   administrator the first time
#   mongodb_ctl.sh stop           - stop MongoDB (it finishes writing its data first)
#   mongodb_ctl.sh restart        - stop, then start
#   mongodb_ctl.sh set-password   - a new password for its administrator, read from the input (one line)
#   mongodb_ctl.sh create-db <db> - a database with a login of its own (its name and password printed: user password)
#   mongodb_ctl.sh databases      - its databases and their sizes (name bytes, one per line)
#   mongodb_ctl.sh backup         - back up every database (mongodump, while it runs)
#   mongodb_ctl.sh daily          - the daily job: a backup, and keeping its log small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_mongodb"
BIN="${APP_PATH}/binaries/bin"
# MongoDB's own data and log: its user's
DB_PATH="${DATA_PATH}/db"
LOG_PATH="${DATA_PATH}/log"
MONGO_LOG="${LOG_PATH}/mongod.log"
# Its configuration: written at every start, root's, readable by its group
CONF_PATH="${DATA_PATH}/conf"
CONFIG_FILE="${CONF_PATH}/mongod.conf"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
# mongosh's home (root's): its settings, with its usage data to MongoDB ("telemetry") turned off
SHELL_HOME="${DATA_PATH}/shell"
PID_FILE=/var/run/mongodb.pid
PORT=27017
ADMIN=admin
# Its own user and group (created if missing): the IDs used when creating them
MONGO_ID=67
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') mongodb/mongodb_ctl.sh $*" >> ${LOG}
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

# Whether MongoDB is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
mongo_ids() {
    awk -F: '$1 == "mongodb" { print $3 " " $4 }' /etc/passwd
}

# Runs mongosh against MongoDB on the NAS itself, quietly, with a script; logged in as its administrator first when the
# password is known (given to the script in its environment - never on a command line, which other programs can read).
#
# $1 script The JavaScript to run (it can use the admin database as admin, and login() to log in)
#
# Prints its output
shell() {
    ( MONGO_ADMIN_PASSWORD="$(cat "${PASSWORD_FILE}" 2>/dev/null)" HOME="${SHELL_HOME}" \
        exec "${BIN}/mongosh" --quiet --norc --port ${PORT} --eval "
const admin = db.getSiblingDB('admin');
function login() {
    return admin.auth('${ADMIN}', process.env.MONGO_ADMIN_PASSWORD).ok === 1;
}
$1" 2>&1 )
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^mongodb:' /etc/group || addgroup -g ${MONGO_ID} mongodb
    grep -q '^mongodb:' /etc/passwd || adduser -D -H -h "${DB_PATH}" -s /bin/false -u ${MONGO_ID} -G mongodb mongodb

    if [ -z "$(mongo_ids)" ]; then
        log "Could not create the mongodb user (are ID ${MONGO_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(mongo_ids)

    # MongoDB reads the system's random numbers at start-up (it stops at once, silently, without them), which WD's
    # firmware lets only root read (standard Linux: everyone). Reading them is harmless, so other users get read access
    # - as on any other Linux system
    for device in /dev/urandom /dev/random; do
        if [ -c "${device}" ] && [ "$(stat -c %A "${device}" | cut -c 8)" != r ]; then
            chmod o+r "${device}" && log "made ${device} readable by all users (as on standard Linux): MongoDB needs it"
        fi
    done

    # Its folder: root's (settings, password, backups), passable for MongoDB; its configuration readable by its group;
    # its data and log its own
    mkdir -p "${DB_PATH}" "${LOG_PATH}" "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"
    chown -R "$1:$2" "${DB_PATH}" "${LOG_PATH}"
    chmod 700 "${DB_PATH}" "${LOG_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LISTEN=local\nCACHE_MB=512\nBACKUP_DIR=\nBACKUP_KEEP=7\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # mongosh's settings: no usage data sent to MongoDB, no greeting
    mkdir -p "${SHELL_HOME}/.mongodb/mongosh"
    chmod 700 "${SHELL_HOME}"
    printf '{"enableTelemetry":false,"disableGreetingMessage":true}\n' > "${SHELL_HOME}/.mongodb/mongosh/config"
}

# Writes MongoDB's configuration: its data and log, where it listens, logins required, and its cache's size (MongoDB
# would otherwise take half the NAS's memory, less 1GB).
#
# Returns 0 once it's written
write_config() {
    set -- $(mongo_ids)
    bind=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && bind=0.0.0.0
    cache_mb="$(setting CACHE_MB 512)"

    case "${cache_mb}" in
        ''|*[!0-9]*) cache_mb=512 ;;
    esac

    ( umask 027; cat > "${CONFIG_FILE}.tmp" <<EOF
# Written by the MongoDB app at every start (mongodb_ctl.sh) - changes here are lost
storage:
  dbPath: ${DB_PATH}
  wiredTiger:
    engineConfig:
      cacheSizeGB: $(awk -v mb="${cache_mb}" 'BEGIN { printf "%.2f", mb / 1024 }')
systemLog:
  destination: file
  path: ${MONGO_LOG}
  logAppend: true
  logRotate: reopen
net:
  port: ${PORT}
  bindIp: ${bind}
security:
  authorization: enabled
processManagement:
  pidFilePath: ${LOG_PATH}/mongod.pid
EOF
    ) && chown "root:$2" "${CONFIG_FILE}.tmp" && chmod 640 "${CONFIG_FILE}.tmp" \
        && mv -f "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
}

# Whether MongoDB answers (a ping: no login needed), while it's still running.
#
# $1 wait Seconds to wait
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt "$1" ]; do
        running || return 1
        shell 'print(db.runCommand({ ping: 1 }).ok)' | grep -q '^1$' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# Makes its administrator (root on every database) with a generated password, through MongoDB's "localhost exception":
# the first user can be made from the NAS itself while there is none.
#
# Returns 0 once it's made
create_admin() {
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) || return 1
    output="$( MONGO_NEW_PASSWORD="${password}" HOME="${SHELL_HOME}" "${BIN}/mongosh" --quiet --norc --port ${PORT} \
        --eval "
db.getSiblingDB('admin').createUser({ user: '${ADMIN}', pwd: process.env.MONGO_NEW_PASSWORD, roles: ['root'] });
print('created')" 2>&1)"

    if ! echo "${output}" | grep -q '^created$'; then
        rm -f "${PASSWORD_FILE}.tmp"
        log "Could not make its administrator: $(echo "${output}" | tail -n 3)"

        return 1
    fi

    mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    log "made its administrator: ${ADMIN} (its password is shown on the app's page)"
}

# Restarts the Compass Web app, if it's installed and running (it logs in to MongoDB as its administrator, with the
# password it reads when it starts)
restart_compass() {
    compass="${APPS_PATH}/compass-web/cw_ctl.sh"

    if [ -f "${compass}" ] && [ -f /var/run/compass-web.pid ]; then
        sh "${compass}" restart > /dev/null 2>&1
    fi
}

start() {
    if running; then
        log "MongoDB is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    write_config || { log "Could not write its configuration: ${CONFIG_FILE}"; return 1; }
    set -- $(mongo_ids)
    log "starting MongoDB on port ${PORT} (log: ${MONGO_LOG})"
    # Its own libraries (OpenSSL) are found next to it; the files it makes are its own only
    ( cd "${DB_PATH}" && umask 077 && HOME="${DB_PATH}" exec "${BIN}/mongodb_runas" "$1" "$2" "${BIN}/mongod" \
        --config "${CONFIG_FILE}" ) >> "${LOG_PATH}/console.log" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up 120; then
        log "MongoDB did not start (see ${MONGO_LOG}): $(tail -n 3 "${LOG_PATH}/console.log" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    # Its first start: its administrator
    if [ ! -s "${PASSWORD_FILE}" ]; then
        create_admin || return 1
    fi

    log "MongoDB started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping MongoDB (PID ${pid})"
        # SIGTERM: it finishes writing its data, then stops
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 60 ]; then
                log 'MongoDB did not stop within 60 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Gives its administrator a new password (from the input): in use at once; the Compass Web app follows.
#
# Returns 0 once it's set
admin_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    output="$(export MONGO_NEW_PASSWORD="${password}"; shell "
if (!login()) { print('login failed'); quit(1); }
admin.changeUserPassword('${ADMIN}', process.env.MONGO_NEW_PASSWORD);
print('changed')")"

    if ! echo "${output}" | grep -q '^changed$'; then
        log "Could not change its administrator's password: $(echo "${output}" | tail -n 3)"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    restart_compass
}

# Makes a database with a login of its own (readWrite and dbAdmin on it only), with a generated password - or gives an
# existing login of that name a new one.
#
# $1 db The database's name (letters, digits, _ and -)
#
# Prints the login's name and password (one line: user password)
create_db() {
    case "$1" in
        ''|admin|local|config|*[!A-Za-z0-9_-]*) log "Not a database name of your own: $1"; return 1 ;;
    esac

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    output="$(export MONGO_NEW_PASSWORD="${password}"; shell "
if (!login()) { print('login failed'); quit(1); }
const target = db.getSiblingDB('$1');
const roles = [{ role: 'readWrite', db: '$1' }, { role: 'dbAdmin', db: '$1' }];
if (target.getUser('$1')) {
    target.updateUser('$1', { pwd: process.env.MONGO_NEW_PASSWORD, roles: roles });
} else {
    target.createUser({ user: '$1', pwd: process.env.MONGO_NEW_PASSWORD, roles: roles });
}
print('done')")"

    if ! echo "${output}" | grep -q '^done$'; then
        log "Could not make the database $1: $(echo "${output}" | tail -n 3)"

        return 1
    fi

    echo "$1 ${password}"
}

# Its databases and their sizes on disk.
#
# Prints one per line: name bytes
databases() {
    shell "
if (!login()) { quit(1); }
admin.adminCommand({ listDatabases: 1 }).databases.forEach(function (d) { print(d.name + ' ' + d.sizeOnDisk); });"
}

# Backs up every database with mongodump (a consistent copy while it runs: --oplog needs a replica set, so each
# collection as it is when it's read), as one compressed archive, root's only, keeping the newest ones. Restored with
# mongorestore (see the app's README).
#
# Returns 0 once it's written
backup() {
    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -s "${PASSWORD_FILE}" ]; then
        log 'Nothing to back up yet (MongoDB has not been set up)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    file="${dir}/mongodb-$(date '+%Y%m%d-%H%M%S').archive.gz"
    # Its login in a configuration file of its own (root's only), not on its command line
    conf="$(mktemp)"
    ( umask 077; printf 'password: "%s"\n' "$(cat "${PASSWORD_FILE}")" > "${conf}" )

    if ! output="$( ( umask 077; "${BIN}/mongodump" --config "${conf}" --host 127.0.0.1 --port ${PORT} \
        --username "${ADMIN}" --authenticationDatabase admin --gzip --archive="${file}.tmp" ) 2>&1)" \
        || ! mv -f "${file}.tmp" "${file}"; then
        rm -f "${conf}" "${file}.tmp"
        log "The backup failed: $(echo "${output}" | tail -n 3)"

        return 1
    fi

    rm -f "${conf}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/mongodb-*.archive.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' \
        | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps MongoDB's log under 5MB: it's asked to start a new one (the previous part is kept as mongod.log.1)
rotate_log() {
    if [ "$(wc -c < "${MONGO_LOG}" 2>/dev/null || echo 0)" -gt 5242880 ] && running; then
        mv -f "${MONGO_LOG}" "${MONGO_LOG}.1"
        # SIGUSR1: it reopens its log (logRotate: reopen)
        kill -USR1 "$(cat "${PID_FILE}")"
    fi
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    set-password) admin_password ;;
    create-db) create_db "$2" ;;
    databases) databases ;;
    backup) backup ;;
    daily) backup; rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|create-db <db>|databases|backup|daily" >&2

        exit 1
        ;;
esac
