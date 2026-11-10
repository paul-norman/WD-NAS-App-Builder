#!/bin/sh
# Runs Vikunja (to-do lists, kanban boards and projects, with CalDAV for phone and desktop to-do apps) as its own user,
# with its data in the persistent path Nas_Prog/_vikunja - kept across reinstalls:
#   vikunja_ctl.sh setup                  - create its user, folders, settings, secret and admin account (where missing)
#   vikunja_ctl.sh start                  - write its configuration, then start it (on port 3456), checking it answers
#   vikunja_ctl.sh stop                   - stop Vikunja
#   vikunja_ctl.sh restart                - stop, then start
#   vikunja_ctl.sh new-password [<user>]  - give a user (default: admin) a new generated password; the admin's is
#                                           kept in admin_password, anyone else's printed
#   vikunja_ctl.sh add-user <name> <email> - add a user with a generated password, and print it
#   vikunja_ctl.sh users                  - list the users: ID, name, email, one per line (tab separated)
#   vikunja_ctl.sh backup                 - back up its database (safely, while it runs) and attachments
#   vikunja_ctl.sh daily                  - the daily job: a backup, and keeping its log small
#   vikunja_ctl.sh nginx                  - rewrite the Nginx app's sites (Vikunja's comes from its nginx.json)
#
# Nobody else can claim it or sign up: the app makes the admin account before Vikunja first starts, and sign-ups are
# off unless the page turns them on. Vikunja only reads passwords from a terminal: vikunja_runas --pty types them in, so
# they're never on a command line

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_vikunja"
# The NAS's PHP finds the Nginx app's site: wherever it is, also with a minimal PATH (e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
VK_DATA="${DATA_PATH}/data"
DB="${VK_DATA}/vikunja.db"
CONFIG="${DATA_PATH}/config.yml"
SETTINGS_FILE="${DATA_PATH}/settings"
SECRET_FILE="${DATA_PATH}/secret"
PASSWORD_FILE="${DATA_PATH}/admin_password"
# Made once the admin account exists (it's never made again: a password changed in Vikunja is kept)
ADMIN_DONE="${DATA_PATH}/admin_created"
VK_LOG="${DATA_PATH}/vikunja.log"
PID_FILE=/var/run/vikunja.pid
PORT=3456
# Its own user and group (created if missing): the IDs used when creating them
VK_ID=59
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') vikunja/vikunja_ctl.sh $*" >> ${LOG}
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

# Whether Vikunja is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them (e.g. 59 59), or nothing if there's no such user
vk_ids() {
    awk -F: '$1 == "vikunja" { print $3 " " $4 }' /etc/passwd
}

# Generates a random text of letters and digits.
#
# $1 length Its length
#
# Prints it
random_text() {
    # (tr complains when head stops reading: nothing else may be printed)
    tr -dc 'A-Za-z0-9' < /dev/urandom 2> /dev/null | head -c "$1"
}

# Runs one of Vikunja's commands as its user, with its configuration - in a pseudo-terminal typing in a password
# (twice, as Vikunja asks) when one is given on this function's input.
#
# $1 pty  pty (type in what's on the input) or plain
# $@      The command and its arguments (e.g. user list)
#
# Prints what Vikunja prints; returns its exit code
vk_cli() {
    local mode="$1"
    # Its user's ID and group ID (two words: split into two arguments below)
    local ids="$(vk_ids)"
    local password

    shift

    if [ "${mode}" = pty ]; then
        password="$(cat)"
        printf '%s\n%s\n' "${password}" "${password}" | ( cd "${VK_DATA}" && "${BIN}/vikunja_runas" --pty ${ids} \
            "${BIN}/vikunja" --config "${CONFIG}" "$@" )
    else
        ( cd "${VK_DATA}" && "${BIN}/vikunja_runas" ${ids} "${BIN}/vikunja" --config "${CONFIG}" "$@" )
    fi
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings and its
# secret (it signs Vikunja's logins: kept, so they last across restarts).
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^vikunja:' /etc/group || addgroup -g ${VK_ID} vikunja
    grep -q '^vikunja:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${VK_ID} -G vikunja vikunja

    if [ -z "$(vk_ids)" ]; then
        log "Could not create the vikunja user (are ID ${VK_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(vk_ids)

    # Its data (the database, attachments) belongs to its user; its configuration (with the secret) to root, readable by
    # its group; the settings, secret and admin password to root alone
    mkdir -p "${VK_DATA}/files"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${VK_DATA}"
    chmod 700 "${VK_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nSIGNUPS=0\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    if [ ! -s "${SECRET_FILE}" ]; then
        ( umask 077; random_text 64 > "${SECRET_FILE}" )
    fi

    touch "${VK_LOG}"
    chmod 600 "${VK_LOG}"
    write_config || return 1
    create_admin
}

# Its address: the Nginx app's site (HTTPS) if it has one, otherwise the NAS's own address on port 3456.
#
# Prints the address, with a trailing /
base_url() {
    local url="$(php "${APP_PATH}/lib/vikunja.php" url "${APPS_PATH}" 2>/dev/null)"
    local ip

    if [ -z "${url}" ]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
        url="http://${ip:-127.0.0.1}:${PORT}"
    fi

    echo "${url%/}/"
}

# Writes Vikunja's configuration (config.yml): its address, its secret, sign-ups (the page's setting), its database and
# attachments in its data folder, the NAS's time zone (WD's php.ini has it) - root's, readable by Vikunja's group.
#
# Prints nothing; returns 0 once written
write_config() {
    local host=127.0.0.1
    local signups=false
    local timezone="$(sed -n 's/^date\.timezone *= *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' /etc/php/php.ini 2>/dev/null \
        | head -n 1)"

    set -- $(vk_ids)
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    [ "$(setting SIGNUPS 0)" = 1 ] && signups=true

    ( umask 027; cat > "${CONFIG}.tmp" <<EOF
# Written by the Vikunja app at every start (vikunja_ctl.sh): changes here are overwritten
service:
  interface: "${host}:${PORT}"
  publicurl: "$(base_url)"
  secret: "$(cat "${SECRET_FILE}")"
  enableregistration: ${signups}
  timezone: "${timezone:-GMT}"
database:
  type: "sqlite"
  path: "${DB}"
files:
  basepath: "${VK_DATA}/files"
log:
  level: "WARNING"
EOF
    ) || return 1
    chown "root:$2" "${CONFIG}.tmp" && chmod 640 "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

# Makes the admin account, once (Vikunja makes its database first): user name admin, a generated password.
#
# Prints what it did; returns 0 once it exists
create_admin() {
    local password

    [ -f "${ADMIN_DONE}" ] && return 0
    password="$(random_text 20)"

    if echo "${password}" | vk_cli pty user create -u admin -e admin@nas.local 2>&1 \
        | grep -q 'created successfully'; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}" )
        touch "${ADMIN_DONE}"
        log 'made the admin account'
    else
        log 'Could not make the admin account (see vikunja user list)'

        return 1
    fi
}

# A user's ID, by name (from Vikunja's database).
#
# $1 name The user name
#
# Prints the ID, or nothing if there's no such user
user_id() {
    case "$1" in
        *[!A-Za-z0-9._-]* | '') return 0 ;;
    esac

    "${BIN}/sqlite3" -readonly "${DB}" "SELECT id FROM users WHERE username = '$1';" 2>/dev/null
}

# Gives a user a new generated password: the admin's is kept in admin_password, anyone else's printed (once).
#
# $1 name The user name (default: admin)
#
# Prints the new password (for a user other than admin - nothing else); returns 0 once set
new_password() {
    local name="${1:-admin}"
    local id="$(user_id "${name}")"
    local password="$(random_text 20)"

    if [ -z "${id}" ]; then
        log "No such user: ${name}"

        return 1
    fi

    if ! echo "${password}" | vk_cli pty user reset-password "${id}" --direct 2>&1 \
        | grep -q 'updated successfully'; then
        log "Could not set a new password for ${name}"

        return 1
    fi

    if [ "${name}" = admin ]; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
            && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    else
        echo "${password}"
    fi

    log "gave ${name} a new password" > /dev/null
}

# Adds a user with a generated password.
#
# $1 name  The user name (letters, digits, . _ -)
# $2 email Their email address
#
# Prints the password (once - nothing else); returns 0 once added
add_user() {
    local password="$(random_text 20)"

    case "$1" in
        *[!A-Za-z0-9._-]* | '') log "Not a user name: $1"; return 1 ;;
    esac

    if [ -n "$(user_id "$1")" ]; then
        log "There's already a user called $1"

        return 1
    fi

    if ! echo "${password}" | vk_cli pty user create -u "$1" -e "$2" 2>&1 | grep -q 'created successfully'; then
        log "Could not add the user $1"

        return 1
    fi

    echo "${password}"
    log "added the user $1" > /dev/null
}

# Waits (up to 90 seconds - its first start creates the database) for Vikunja to answer, while it's still running.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 90 ]; do
        running || return 1
        curl -s -m 2 "http://127.0.0.1:${PORT}/api/v1/info" 2>/dev/null | grep -q '"version"' && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Writes its configuration, then starts it as its own user, in the background (its output in its log), on the NAS
# itself or on every address.
#
# Prints what it did; returns 0 once it answers
start() {
    if running; then
        log "Vikunja is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    set -- $(vk_ids)
    log "starting Vikunja on port ${PORT} (log: ${VK_LOG})"
    cd "${VK_DATA}" || return 1
    ( exec env HOME="${VK_DATA}" "${BIN}/vikunja_runas" "$1" "$2" "${BIN}/vikunja" --config "${CONFIG}" web ) \
        >> "${VK_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Vikunja did not start (see ${VK_LOG}): $(tail -n 3 "${VK_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Vikunja started with PID: $(cat ${PID_FILE})"
}

# Stops it: politely first, then (after 20 seconds) by force.
#
# Prints what it did; returns 0 once stopped
stop() {
    local pid
    local waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Vikunja (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Vikunja did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Backs up its database (SQLite's online backup: a consistent copy while Vikunja writes to it, checked) and its
# attachments, as one .tar.gz in Nas_Prog/_vikunja/backups - root's only - keeping the newest ones.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    local work="${dir}/.vikunja-${stamp}"
    local file="${dir}/vikunja-${stamp}.tar.gz"
    local old

    if [ ! -f "${DB}" ]; then
        log 'Nothing to back up yet (no database - Vikunja has not started yet)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    if ! "${BIN}/sqlite3" "${DB}" ".backup '${work}/vikunja.db'" \
        || [ "$("${BIN}/sqlite3" "${work}/vikunja.db" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    cp -a "${VK_DATA}/files" "${work}/" || { rm -rf "${work}"; return 1; }

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . ) || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -rf "${work}" "${file}.tmp"

        return 1
    fi

    rm -rf "${work}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/vikunja-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps its log under 1MB (the previous part is kept as vikunja.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${VK_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${VK_LOG}" "${VK_LOG}.1" && : > "${VK_LOG}"
        chmod 600 "${VK_LOG}.1"
    fi

    return 0
}

# The Nginx app finds Vikunja by its folder (its nginx.json) and serves it at https://vikunja.<its domain>: rewrite its
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
    new-password) new_password "$2" ;;
    add-user) add_user "$2" "$3" ;;
    users)
        "${BIN}/sqlite3" -readonly -separator "$(printf '\t')" "${DB}" \
            'SELECT id, username, email FROM users ORDER BY id;'
        ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password [<user>]|add-user <name> <email>|users|backup|daily" \
            "|nginx" >&2

        exit 1
        ;;
esac
