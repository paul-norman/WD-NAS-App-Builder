#!/bin/sh
# Runs Forgejo (Git hosting) as its own user, with everything it keeps in the persistent path (Nas_Prog/_forgejo - kept
# across reinstalls):
#   forgejo_ctl.sh setup          - create its user, folders, settings and app.ini (where missing)
#   forgejo_ctl.sh start          - update its address etc. in app.ini, create the admin user (once), then start it (web on
#                                   port 3002: the network, or the NAS itself only; Git over SSH on port 2222)
#   forgejo_ctl.sh stop           - stop Forgejo
#   forgejo_ctl.sh restart        - stop, then start
#   forgejo_ctl.sh new-password   - give the admin user a new (generated) password
#   forgejo_ctl.sh backup         - a full backup with Forgejo's own dump (repositories, database, settings), while it runs
#   forgejo_ctl.sh daily          - the daily job: a backup when one is due, and keeping the log small
#   forgejo_ctl.sh nginx          - add / update Forgejo's site in the Nginx app (and reload it)
#
# app.ini is created once, with generated secrets, and is Forgejo's to change (e.g. its mailer): the app only keeps the
# address, listening address, SSH server and git program in it current (see lib/forgejo.php)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_forgejo"
# PHP updates app.ini: wherever it is, also when run with a minimal PATH, e.g. from the management page
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
GIT="${BIN}/git/bin/git"
INI="${DATA_PATH}/custom/conf/app.ini"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
FORGEJO_LOG="${DATA_PATH}/forgejo.log"
BACKUP_DIR="${DATA_PATH}/backups"
PID_FILE=/var/run/forgejo.pid
BACKUP_PID_FILE=/var/run/forgejo-backup.pid
PORT=3002
SSH_PORT=2222
ADMIN=nas-admin
# Its own user and group (created if missing): the IDs used when creating them
FORGEJO_ID=77
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') forgejo/forgejo_ctl.sh $*" >> ${LOG}
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

# The user's ID and group ID, from the NAS's own user list
forgejo_ids() {
    awk -F: '$1 == "forgejo" { print $3 " " $4 }' /etc/passwd
}

# Runs a forgejo command as its user, with its settings
forgejo_cmd() {
    set -- $(forgejo_ids) "$@"
    uid=$1
    gid=$2
    shift 2
    ( cd "${DATA_PATH}" && exec env HOME="${DATA_PATH}/data/home" USER=forgejo "${BIN}/forgejo_runas" "${uid}" "${gid}" \
        "${BIN}/forgejo" --work-path "${DATA_PATH}" --config "${INI}" "$@" )
}

# Writes app.ini, with newly generated secrets (only when there's none yet: it then belongs to Forgejo)
create_ini() {
    secret_key="$("${BIN}/forgejo" generate secret SECRET_KEY)"
    internal_token="$("${BIN}/forgejo" generate secret INTERNAL_TOKEN)"
    jwt_secret="$("${BIN}/forgejo" generate secret JWT_SECRET)"
    lfs_jwt_secret="$("${BIN}/forgejo" generate secret LFS_JWT_SECRET)"

    if [ -z "${secret_key}" ] || [ -z "${internal_token}" ] || [ -z "${jwt_secret}" ] || [ -z "${lfs_jwt_secret}" ]; then
        log "Could not generate Forgejo's secrets"

        return 1
    fi
    log "creating Forgejo's settings: ${INI}"
    ( umask 077; cat > "${INI}.tmp" <<EOF
; Forgejo's settings, created by the Forgejo app (see https://forgejo.org/docs/latest/admin/config-cheat-sheet/), then
; restart Forgejo on its management page after a change. The app updates only these at every start: [server] ROOT_URL,
; DOMAIN, SSH_DOMAIN, HTTP_ADDR, START_SSH_SERVER and DISABLE_SSH, and [git] PATH
APP_NAME = Forgejo
RUN_USER = forgejo
RUN_MODE = prod
WORK_PATH = ${DATA_PATH}

[server]
PROTOCOL = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${PORT}
ROOT_URL = http://127.0.0.1:${PORT}/
DOMAIN = 127.0.0.1
APP_DATA_PATH = ${DATA_PATH}/data
; Git over SSH: Forgejo's own SSH server (the NAS's own SSH is left alone)
START_SSH_SERVER = true
DISABLE_SSH = false
SSH_DOMAIN = 127.0.0.1
SSH_PORT = ${SSH_PORT}
SSH_LISTEN_PORT = ${SSH_PORT}
BUILTIN_SSH_SERVER_USER = git
LFS_START_SERVER = true
LFS_JWT_SECRET = ${lfs_jwt_secret}
; Nothing loaded from other sites (e.g. avatars from Gravatar)
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = ${DATA_PATH}/data/forgejo.db
SQLITE_JOURNAL_MODE = WAL

[repository]
ROOT = ${DATA_PATH}/repositories
; The repositories' hooks run with the NAS's sh (it has no bash)
SCRIPT_TYPE = sh
DEFAULT_PRIVATE = private
DEFAULT_BRANCH = main

[git]
PATH = ${GIT}

[security]
INSTALL_LOCK = true
SECRET_KEY = ${secret_key}
INTERNAL_TOKEN = ${internal_token}

[oauth2]
JWT_SECRET = ${jwt_secret}

; Only users the admin creates, and nothing visible without logging in
[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
DEFAULT_KEEP_EMAIL_PRIVATE = true
NO_REPLY_ADDRESS = noreply.localhost

[session]
PROVIDER = db

[mailer]
ENABLED = false

; Forgejo Actions need a separate runner (e.g. in Docker): turn on once there is one
[actions]
ENABLED = false

[cron.update_checker]
ENABLED = false

[log]
MODE = console
LEVEL = Warn
ROOT_PATH = ${DATA_PATH}/log
EOF
    ) && mv -f "${INI}.tmp" "${INI}"
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^forgejo:' /etc/group || addgroup -g ${FORGEJO_ID} forgejo
    grep -q '^forgejo:' /etc/passwd || adduser -D -H -h "${DATA_PATH}/data/home" -s /bin/false -u ${FORGEJO_ID} -G forgejo forgejo

    if [ -z "$(forgejo_ids)" ]; then
        log "Could not create the forgejo user (are ID ${FORGEJO_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(forgejo_ids)

    # Its repositories, data, settings and backups belong to its user (not recursively: repositories can be large, and
    # Forgejo creates everything in them as its user); the page's settings, admin password and log to root
    mkdir -p "${DATA_PATH}/custom/conf" "${DATA_PATH}/data/home" "${DATA_PATH}/repositories" "${DATA_PATH}/log" "${BACKUP_DIR}"
    chmod 711 "${DATA_PATH}"

    for dir in custom custom/conf data data/home repositories log backups; do
        chown "$1:$2" "${DATA_PATH}/${dir}"
        chmod 700 "${DATA_PATH}/${dir}"
    done

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LISTEN=all\nSSH=1\nBACKUP=weekly\nBACKUP_KEEP=4\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    if [ ! -s "${INI}" ]; then
        create_ini || return 1
    fi

    chown "$1:$2" "${INI}"
    chmod 600 "${INI}"
    touch "${FORGEJO_LOG}"
    chmod 600 "${FORGEJO_LOG}"
}

# The app's settings in app.ini: the address (the Nginx app's site, or the NAS's own address on port 3002), listening
# address, SSH server and git program
configure() {
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"

    php "${APP_PATH}/lib/forgejo.php" configure "${APPS_PATH}" "${INI}" "$(setting LISTEN all)" "$(setting SSH 1)" \
        "${ip:-127.0.0.1}" "${GIT}"
}

# The admin user, with a generated password (once: the password is kept, root only, for the management page)
create_admin() {
    [ -s "${PASSWORD_FILE}" ] && return 0

    # The database needs creating first, on the first start
    if ! output="$(forgejo_cmd migrate 2>&1)"; then
        log "Could not create Forgejo's database: ${output}"

        return 1
    fi

    status=0
    output="$(forgejo_cmd admin user create --admin --username "${ADMIN}" --email "${ADMIN}@noreply.localhost" \
        --random-password --random-password-length 20 --must-change-password=false 2>&1)" || status=1
    password="$(echo "${output}" | sed -n "s/.*generated random password is '\([^']*\)'.*/\1/p" | head -n 1)"

    if [ ${status} = 0 ] && [ -n "${password}" ]; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
        log "created the admin user: ${ADMIN}"
    elif echo "${output}" | grep -q 'already exists'; then
        # Its data was kept, without the password file
        new_password
    else
        log "Could not create the admin user: ${output}"

        return 1
    fi
}

# A new generated password for the admin user. (Forgejo only takes it on the command line: it's there for a moment)
new_password() {
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"

    if output="$(forgejo_cmd admin user change-password --username "${ADMIN}" --password "${password}" \
        --must-change-password=false 2>&1)"; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
        log "gave the admin user (${ADMIN}) a new password"
    else
        log "Could not change the admin user's password: ${output}"

        return 1
    fi
}

start() {
    if running; then
        log "Forgejo is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    configure || { log "Could not update Forgejo's settings: ${INI}"; return 1; }
    create_admin || return 1

    set -- $(forgejo_ids)
    log "starting Forgejo on port ${PORT} (log: ${FORGEJO_LOG})"

    # Its log is appended to (so that it can be cut short while it runs)
    cd "${DATA_PATH}" || return 1
    ( exec env HOME="${DATA_PATH}/data/home" USER=forgejo "${BIN}/forgejo_runas" "$1" "$2" "${BIN}/forgejo" web \
        --work-path "${DATA_PATH}" --config "${INI}" ) >> "${FORGEJO_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Forgejo started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Forgejo (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Forgejo did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# A full backup (Forgejo's dump: repositories, database, settings, attachments, LFS files) to backups/, keeping the
# newest BACKUP_KEEP. It's safe while Forgejo runs
backup() {
    if [ -f "${BACKUP_PID_FILE}" ] && kill -0 "$(cat "${BACKUP_PID_FILE}")" 2>/dev/null; then
        log 'A backup is already running'

        return 1
    fi

    if [ ! -f "${DATA_PATH}/data/forgejo.db" ]; then
        log 'Nothing to back up yet (no database - start Forgejo first)'

        return 1
    fi

    echo $$ > "${BACKUP_PID_FILE}"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    file="${BACKUP_DIR}/forgejo-${stamp}.tar.gz"
    # Written under another name until it's complete: the dump adds the .tar.gz
    partial="${BACKUP_DIR}/partial-${stamp}.tar.gz"
    log "backing up Forgejo to: ${file}"
    # Its temporary files go next to the backups, not to /tmp - in the NAS's RAM
    mkdir -p "${BACKUP_DIR}/tmp"
    set -- $(forgejo_ids)
    chown "$1:$2" "${BACKUP_DIR}/tmp"

    if output="$(forgejo_cmd dump --quiet --type tar.gz --skip-index --skip-repo-archives --tempdir "${BACKUP_DIR}/tmp" \
        --file "${partial}" 2>&1)" && mv -f "${partial}" "${file}"; then
        log "backed up Forgejo: ${file} ($(du -h "${file}" | cut -f 1))"
        status=0
    else
        log "The backup failed: ${output}"
        rm -f "${partial}"
        status=1
    fi

    rm -rf "${BACKUP_DIR}/tmp"
    # Keep only the newest backups
    ls -1 "${BACKUP_DIR}"/forgejo-*.tar.gz 2>/dev/null | sort -r | awk -v keep="$(setting BACKUP_KEEP 4)" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done

    rm -f "${BACKUP_PID_FILE}"

    return ${status}
}

# A backup when one is due (BACKUP: daily, weekly - on Sundays - or off)
backup_due() {
    case "$(setting BACKUP weekly)" in
        daily) backup ;;
        weekly) [ "$(date +%w)" = 0 ] && backup ;;
    esac

    return 0
}

# Keeps Forgejo's log under 1MB (the previous part is kept as forgejo.log.1)
rotate_log() {
    if [ "$(wc -c < "${FORGEJO_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${FORGEJO_LOG}" "${FORGEJO_LOG}.1" && : > "${FORGEJO_LOG}"
        chmod 600 "${FORGEJO_LOG}.1"
    fi
}

# The Nginx app finds Forgejo by its folder and serves it at https://git.<its domain>: rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    new-password) new_password ;;
    backup) backup ;;
    daily) backup_due; rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
