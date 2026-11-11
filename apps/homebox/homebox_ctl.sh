#!/bin/sh
# Runs Homebox (a home inventory) as its own user, with its data in the persistent path Nas_Prog/_homebox - kept
# across reinstalls:
#   homebox_ctl.sh setup              - create its user, folders, settings, secret and admin password (where missing)
#   homebox_ctl.sh start              - start it (on port 7745), checking that it answers; the first time, its admin
#                                       account is made first
#   homebox_ctl.sh stop               - stop Homebox
#   homebox_ctl.sh restart            - stop, then start
#   homebox_ctl.sh new-password       - give the admin account a new password (Homebox must be running)
#   homebox_ctl.sh reset-link <email> - print a one-time password reset link for an account (valid for an hour)
#   homebox_ctl.sh backup             - back up its database (safely, while it runs) and attachments
#   homebox_ctl.sh daily              - the daily job: a backup, and keeping its log small
#   homebox_ctl.sh nginx              - rewrite the Nginx app's sites (Homebox's own comes from its nginx.json), and
#                                       reload it
#
# Nobody else can claim it: a new Homebox lets whoever signs up first in, so its first start only listens on the NAS
# itself, with sign-ups allowed just long enough for the app to make the admin account. After that, sign-ups are off
# (the page's setting): others join through Homebox's own invitation links, which work regardless

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_homebox"
# The NAS's PHP finds the Nginx app's site: wherever it is, also with a minimal PATH (e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
# Its database and attachments (its user's only), and its temporary files - on the same disk: Homebox moves uploads
# into place, which fails across disks (the NAS's /tmp is in memory)
HOMEBOX_DATA="${DATA_PATH}/data"
HOMEBOX_TMP="${DATA_PATH}/tmp"
DATABASE="${HOMEBOX_DATA}/homebox.db"
# How Homebox opens it (its own defaults)
DATABASE_OPTIONS='_pragma=busy_timeout=999&_pragma=journal_mode=WAL&_fk=1&_time_format=sqlite'
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
# Homebox's secret for its API keys (it won't start without one, and changing it voids every API key)
PEPPER_FILE="${DATA_PATH}/api_key_pepper"
# The address it was last started with
ADDRESS_FILE="${DATA_PATH}/address"
# Made once the admin account exists
CLAIMED="${DATA_PATH}/admin_created"
HOMEBOX_LOG="${DATA_PATH}/homebox.log"
PID_FILE=/var/run/homebox.pid
PORT=7745
ADMIN_EMAIL='admin@homebox.local'
# Its own user and group (created if missing): the IDs used when creating them
HOMEBOX_ID=58
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') homebox/homebox_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"

    echo "${value:-$2}"
}

# Whether Homebox is running (its PID file's process: a number, written since the NAS started).
#
# Returns 0 if it is
running() {
    local pid="$(cat "${PID_FILE}" 2>/dev/null)"

    case "${pid}" in
        '' | *[!0-9]*) return 1 ;;
    esac

    kill -0 "${pid}" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them (e.g. 95 95), or nothing if there's no such user
homebox_ids() {
    awk -F: '$1 == "homebox" { print $3 " " $4 }' /etc/passwd
}

# Writes a secret (letters and digits) to a file only root can read.
#
# $1 file   The file
# $2 length The number of characters
#
# Prints nothing; returns 0 once written
new_secret() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$2" > "$1.tmp" ) && mv -f "$1.tmp" "$1"
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings, its
# secret and the admin password.
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^homebox:' /etc/group || addgroup -g ${HOMEBOX_ID} homebox
    grep -q '^homebox:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${HOMEBOX_ID} -G homebox homebox

    if [ -z "$(homebox_ids)" ]; then
        log "Could not create the homebox user (are ID ${HOMEBOX_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(homebox_ids)

    # Its data and temporary files belong to its user; the settings, the secret and the password to root
    mkdir -p "${HOMEBOX_DATA}" "${HOMEBOX_TMP}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${HOMEBOX_DATA}" "${HOMEBOX_TMP}"
    chmod 700 "${HOMEBOX_DATA}" "${HOMEBOX_TMP}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nSIGNUPS=off\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PEPPER_FILE}" ] || new_secret "${PEPPER_FILE}" 64
    [ -s "${PASSWORD_FILE}" ] || new_secret "${PASSWORD_FILE}" 20
    chmod 600 "${PEPPER_FILE}" "${PASSWORD_FILE}"
    touch "${HOMEBOX_LOG}"
    chmod 600 "${HOMEBOX_LOG}"
}

# Its address: the Nginx app's site (HTTPS) if it has one, otherwise the NAS's own address on port 7745.
#
# Prints the address, without a trailing /
base_url() {
    local url="$(php "${APP_PATH}/lib/homebox.php" url "${APPS_PATH}" 2>/dev/null)"
    local ip

    if [ -z "${url}" ]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
        url="http://${ip:-127.0.0.1}:${PORT}"
    fi

    echo "${url%/}"
}

# Runs Homebox (or one of its commands) as its own user, with its settings in its environment - in place of the
# current shell, so it's only called in a subshell.
#
# $1 host    The address it listens on (127.0.0.1 or 0.0.0.0)
# $2 signups Whether people may sign themselves up (true or false)
# $@         The program and its arguments (Homebox: its web server, or one of its commands)
#
# Doesn't return
run_homebox() {
    local host="$1"
    local signups="$2"
    local trust=false

    shift 2
    # Behind the Nginx app only: its forwarded headers (the browser's address and HTTPS) can be trusted
    [ "${host}" = 127.0.0.1 ] && trust=true
    set -- $(homebox_ids) "$@"
    cd "${HOMEBOX_DATA}" || exit 1
    exec env HOME="${HOMEBOX_DATA}" TMPDIR="${HOMEBOX_TMP}" \
        HBOX_MODE=production \
        HBOX_WEB_HOST="${host}" \
        HBOX_WEB_PORT="${PORT}" \
        HBOX_WEB_MAX_UPLOAD_SIZE=100 \
        HBOX_STORAGE_CONN_STRING="file://${DATA_PATH}" \
        HBOX_STORAGE_PREFIX_PATH=data \
        HBOX_DATABASE_DRIVER=sqlite3 \
        HBOX_DATABASE_SQLITE_PATH="${DATABASE}?${DATABASE_OPTIONS}" \
        HBOX_AUTH_API_KEY_PEPPER="$(cat "${PEPPER_FILE}")" \
        HBOX_OPTIONS_ALLOW_REGISTRATION="${signups}" \
        HBOX_OPTIONS_TRUST_PROXY="${trust}" \
        HBOX_OPTIONS_HOSTNAME="$(base_url)" \
        HBOX_OPTIONS_ALLOW_ANALYTICS=false \
        HBOX_OPTIONS_GITHUB_RELEASE_CHECK=false \
        "${BIN}/homebox_runas" "$@"
}

# Starts Homebox's web server in the background (its output in its log).
#
# $1 host    The address it listens on (127.0.0.1 or 0.0.0.0)
# $2 signups Whether people may sign themselves up (true or false)
#
# Prints nothing; returns 0 once started
launch() {
    ( run_homebox "$1" "$2" "${BIN}/homebox" ) >> "${HOMEBOX_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
}

# Waits (up to 90 seconds - its first start creates the database) for Homebox to answer, while it's still running.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 90 ]; do
        running || return 1
        curl -s -m 2 "http://127.0.0.1:${PORT}/api/v1/status" 2>/dev/null | grep -q '"health":true' && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Makes the admin account, the first time: Homebox started on the NAS itself only, with sign-ups allowed, the account
# signed up through its API, then Homebox stopped again. A database that already has accounts (e.g. its marker was
# lost) is left as it is.
#
# Prints what it did; returns 0 once the admin account exists
claim() {
    local users code

    # (Only an existing database: sqlite3 would make an empty one - root's, which Homebox then couldn't write to)
    [ -f "${DATABASE}" ] && users="$("${BIN}/sqlite3" -readonly "${DATABASE}" 'SELECT count(*) FROM users;' 2>/dev/null)"

    if [ "${users:-0}" -gt 0 ]; then
        log "Homebox already has ${users} account(s): no admin account made"
        touch "${CLAIMED}"

        return 0
    fi

    log 'first start: making the admin account (Homebox only on the NAS itself meanwhile)'
    launch 127.0.0.1 true

    if ! wait_up; then
        log "Homebox did not start (see ${HOMEBOX_LOG}): $(tail -n 3 "${HOMEBOX_LOG}" 2>/dev/null | tr '\n' ' ')"
        stop

        return 1
    fi

    code="$(printf '{"name":"Admin","email":"%s","password":"%s"}' "${ADMIN_EMAIL}" "$(cat "${PASSWORD_FILE}")" \
        | curl -s -m 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:${PORT}/api/v1/users/register")"
    stop

    if [ "${code}" != 204 ]; then
        log "Could not make the admin account (Homebox answered ${code})"

        return 1
    fi

    touch "${CLAIMED}"
    log "made the admin account: ${ADMIN_EMAIL}"
}

# Starts it as its own user, on the NAS itself or on every address - after making the admin account, the first time.
#
# Prints what it did; returns 0 once it answers
start() {
    local host=127.0.0.1
    local signups=false

    if running; then
        log "Homebox is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    if [ ! -f "${CLAIMED}" ]; then
        claim || return 1
    fi

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    [ "$(setting SIGNUPS off)" = on ] && signups=true
    log "starting Homebox on ${host}:${PORT}, sign-ups ${signups} (log: ${HOMEBOX_LOG})"
    launch "${host}" "${signups}"
    # The address it was given for its links (the page says when the Nginx app's has changed since)
    base_url > "${ADDRESS_FILE}"

    if ! wait_up; then
        log "Homebox did not start (see ${HOMEBOX_LOG}): $(tail -n 3 "${HOMEBOX_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Homebox started with PID: $(cat ${PID_FILE})"
}

# Stops it: politely first, then (after 20 seconds) by force.
#
# Prints what it did; returns 0 once stopped
stop() {
    local pid
    local waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Homebox (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Homebox did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# A one-time password reset link for an account, from Homebox's own command (valid for an hour, used once).
#
# $1 email The account's email address
#
# Prints the link; returns 0 if there's such an account
reset_link() {
    local link

    case "$1" in
        *@*) ;;
        *)
            echo 'Give the account'"'"'s email address' >&2

            return 2
            ;;
    esac

    link="$(run_homebox 127.0.0.1 false "${BIN}/homebox" reset-password "--email=$1" 2>&1)" || {
        echo "${link}" | tail -n 1 >&2

        return 1
    }
    echo "${link}" | grep -E '^https?://' | tail -n 1
}

# Gives the admin account a new password (letters and digits), through a reset token from Homebox's own command - so
# its sign-ins elsewhere are kept. Homebox must be running.
#
# Prints what it did; returns 0 once set
new_password() {
    local link token password code

    running || {
        log 'Homebox is not running: start it first'

        return 1
    }
    link="$(reset_link "${ADMIN_EMAIL}")" || {
        log "Homebox has no account ${ADMIN_EMAIL} any more (changed in Homebox?): use a reset link for its address"

        return 1
    }
    token="${link##*token=}"
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    code="$(printf '{"token":"%s","password":"%s"}' "${token}" "${password}" \
        | curl -s -m 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:${PORT}/api/v1/users/reset-password")"

    if [ "${code}" != 204 ]; then
        log "Homebox refused the new password (it answered ${code})"

        return 1
    fi

    ( umask 077; printf '%s' "${password}" > "${PASSWORD_FILE}" )
    log 'set a new admin password'
}

# Backs up its database (SQLite's online backup: a consistent copy while Homebox writes to it, checked) and the rest of
# its data folder (attachments), as one .tar.gz in Nas_Prog/_homebox/backups - root's only - keeping the newest ones.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    local work="${dir}/.homebox-${stamp}"
    local file="${dir}/homebox-${stamp}.tar.gz"
    local item

    if [ ! -f "${DATABASE}" ]; then
        log 'Nothing to back up yet (no database - Homebox has not started yet)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    if ! "${BIN}/sqlite3" "${DATABASE}" ".backup '${work}/homebox.db'" \
        || [ "$("${BIN}/sqlite3" "${work}/homebox.db" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    # Everything else it keeps (attachments, a folder per group), not the live database's own files
    for item in "${HOMEBOX_DATA}"/* "${HOMEBOX_DATA}"/.[!.]*; do
        [ -e "${item}" ] || continue

        case "$(basename "${item}")" in
            homebox.db | homebox.db-*) ;;
            *) cp -a "${item}" "${work}/" ;;
        esac
    done

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . ) || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -rf "${work}" "${file}.tmp"

        return 1
    fi

    rm -rf "${work}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/homebox-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r item; do
        rm -f "${item}"
    done
}

# Keeps its log under 1MB (the previous part is kept as homebox.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${HOMEBOX_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${HOMEBOX_LOG}" "${HOMEBOX_LOG}.1" && : > "${HOMEBOX_LOG}"
        chmod 600 "${HOMEBOX_LOG}.1"
    fi

    return 0
}

# The Nginx app finds Homebox by its folder (its nginx.json) and serves it at https://homebox.<its domain>: rewrite its
# sites, and reload it.
#
# Prints nothing; returns 0 (with or without the Nginx app)
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
            && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
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
    new-password) new_password ;;
    reset-link) reset_link "$2" ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|reset-link <email>|backup|daily|nginx" >&2

        exit 1
        ;;
esac
