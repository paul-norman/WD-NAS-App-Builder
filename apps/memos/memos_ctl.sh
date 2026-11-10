#!/bin/sh
# Runs Memos (notes: quick, Markdown, tagged and searchable) as its own user, with its data in the persistent path
# Nas_Prog/_memos - kept across reinstalls:
#   memos_ctl.sh setup        - create its user, folders, settings and the admin password (where missing)
#   memos_ctl.sh start        - write its configuration, then start it (on port 5230), checking that it answers
#   memos_ctl.sh stop         - stop Memos
#   memos_ctl.sh restart      - stop, then start
#   memos_ctl.sh new-password - set a new admin password (applied when Memos next starts)
#   memos_ctl.sh backup       - back up its database (safely, while it runs) and attachments
#   memos_ctl.sh daily        - the daily job: a backup, and keeping its log small
#   memos_ctl.sh nginx        - rewrite the Nginx app's sites (Memos' own comes from its nginx.json), and reload it
#
# Nobody else can claim the instance: its admin user is declared in Memos' own configuration files (config/app.json -
# Memos applies them at every start), with the password read from a file. The password is only sent when its version
# goes up (new-password), so a password changed in Memos is kept. On the first start the files also turn sign-ups off,
# then hand that setting back to Memos' own settings page

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_memos"
# The NAS's PHP finds the Nginx app's site: wherever it is, also with a minimal PATH (e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
MEMOS_DATA="${DATA_PATH}/data"
CONFIG_DIR="${DATA_PATH}/config"
CONFIG="${CONFIG_DIR}/app.json"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
VERSION_FILE="${DATA_PATH}/admin_password_version"
# Made once sign-ups have been turned off on the first start (the setting is Memos' own after that)
SIGNUPS_DONE="${DATA_PATH}/signups_set"
MEMOS_LOG="${DATA_PATH}/memos.log"
PID_FILE=/var/run/memos.pid
PORT=5230
# Its own user and group (created if missing): the IDs used when creating them
MEMOS_ID=61
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') memos/memos_ctl.sh $*" >> ${LOG}
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

# Whether Memos is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them (e.g. 100 100), or nothing if there's no such user
memos_ids() {
    awk -F: '$1 == "memos" { print $3 " " $4 }' /etc/passwd
}

# Sets a new admin password (letters and digits): readable by root and Memos' group only, as Memos reads it from its
# configuration. Its version goes up, so Memos sets it when it next starts.
#
# Prints nothing; returns 0 once written
new_password() {
    local version="$(cat "${VERSION_FILE}" 2>/dev/null)"

    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) || return 1
    set -- $(memos_ids)
    [ -n "$2" ] && chown "root:$2" "${PASSWORD_FILE}.tmp" && chmod 640 "${PASSWORD_FILE}.tmp"
    mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}" || return 1
    echo $((${version:-0} + 1)) > "${VERSION_FILE}"
    chmod 600 "${VERSION_FILE}"
    log 'generated a new admin password'
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings and the
# admin password.
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^memos:' /etc/group || addgroup -g ${MEMOS_ID} memos
    grep -q '^memos:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${MEMOS_ID} -G memos memos

    if [ -z "$(memos_ids)" ]; then
        log "Could not create the memos user (are ID ${MEMOS_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(memos_ids)

    # Its data (the database, attachments) belongs to its user; its configuration, the password and the settings to
    # root (the first two readable by its group: Memos reads them)
    mkdir -p "${MEMOS_DATA}" "${CONFIG_DIR}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${MEMOS_DATA}"
    chmod 700 "${MEMOS_DATA}"
    chown "root:$2" "${CONFIG_DIR}"
    chmod 750 "${CONFIG_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password
    chown "root:$2" "${PASSWORD_FILE}"
    chmod 640 "${PASSWORD_FILE}"
    touch "${MEMOS_LOG}"
    chmod 600 "${MEMOS_LOG}"
}

# Its address: the Nginx app's site (HTTPS) if it has one, otherwise the NAS's own address on port 5230.
#
# Prints the address, without a trailing /
base_url() {
    local url="$(php "${APP_PATH}/lib/memos.php" url "${APPS_PATH}" 2>/dev/null)"
    local ip

    if [ -z "${url}" ]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
        url="http://${ip:-127.0.0.1}:${PORT}"
    fi

    echo "${url%/}"
}

# Writes Memos' declarative configuration (config/app.json): the admin user, with its password read from its file and
# sent only when its version goes up; and, until the first start has done it, sign-ups turned off - then released, so
# the setting is Memos' own (changed in its settings page) without being reset.
#
# Prints nothing; returns 0 once written
write_config() {
    local version="$(cat "${VERSION_FILE}" 2>/dev/null)"
    local signups='"removed": [ { "resource": "instance/settings/GENERAL" } ],'

    set -- $(memos_ids)

    if [ ! -f "${SIGNUPS_DONE}" ]; then
        signups='"instanceSettings": [
        { "name": "instance/settings/GENERAL", "generalSetting": { "disallowUserRegistration": true } }
    ],'
    fi

    ( umask 027; cat > "${CONFIG}.tmp" <<EOF
{
    "users": [
        { "name": "users/admin", "username": "admin", "role": "ADMIN", "password": "\${file:${PASSWORD_FILE}}" }
    ],
    ${signups}
    "lifecycle": [
        { "resource": "users/admin", "preventDestroy": true, "writeOnlyVersion": ${version:-1} }
    ]
}
EOF
    ) || return 1
    chown "root:$2" "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

# Waits (up to 90 seconds - its first start creates the database) for Memos to answer, while it's still running.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 90 ]; do
        running || return 1
        curl -s -m 2 "http://127.0.0.1:${PORT}/api/instance/profile" 2>/dev/null | grep -q '"version"' && return 0
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
        log "Memos is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    write_config || return 1

    set -- $(memos_ids)
    local host=127.0.0.1

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting Memos on ${host}:${PORT} (log: ${MEMOS_LOG})"
    cd "${MEMOS_DATA}" || return 1
    ( exec env HOME="${MEMOS_DATA}" "${BIN}/memos_runas" "$1" "$2" "${BIN}/memos" --addr "${host}" --port ${PORT} \
        --data "${MEMOS_DATA}" --config-dir "${CONFIG_DIR}" --instance-url "$(base_url)" ) >> "${MEMOS_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Memos did not start (see ${MEMOS_LOG}): $(tail -n 3 "${MEMOS_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    # Sign-ups were turned off by this start: from now on the setting is Memos' own
    if [ ! -f "${SIGNUPS_DONE}" ]; then
        touch "${SIGNUPS_DONE}"
    fi

    log "Memos started with PID: $(cat ${PID_FILE})"
}

# Stops it: politely first, then (after 20 seconds) by force.
#
# Prints what it did; returns 0 once stopped
stop() {
    local pid
    local waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Memos (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Memos did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Backs up its database (SQLite's online backup: a consistent copy while Memos writes to it, checked) and the rest of
# its data folder (attachments), as one .tar.gz in Nas_Prog/_memos/backups - root's only - keeping the newest ones.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    local work="${dir}/.memos-${stamp}"
    local file="${dir}/memos-${stamp}.tar.gz"
    local item

    if [ ! -f "${MEMOS_DATA}/memos_prod.db" ]; then
        log 'Nothing to back up yet (no database - Memos has not started yet)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    if ! "${BIN}/sqlite3" "${MEMOS_DATA}/memos_prod.db" ".backup '${work}/memos_prod.db'" \
        || [ "$("${BIN}/sqlite3" "${work}/memos_prod.db" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    # Everything else it keeps (attachments stored as files), not the live database's own files
    for item in "${MEMOS_DATA}"/* "${MEMOS_DATA}"/.[!.]*; do
        [ -e "${item}" ] || continue

        case "$(basename "${item}")" in
            memos_prod.db | memos_prod.db-*) ;;
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
    ls -1 "${dir}"/memos-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r item; do
        rm -f "${item}"
    done
}

# Keeps its log under 1MB (the previous part is kept as memos.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${MEMOS_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${MEMOS_LOG}" "${MEMOS_LOG}.1" && : > "${MEMOS_LOG}"
        chmod 600 "${MEMOS_LOG}.1"
    fi

    return 0
}

# The Nginx app finds Memos by its folder (its nginx.json) and serves it at https://memos.<its domain>: rewrite its
# sites, and reload it.
#
# Prints nothing; returns 0 (with or without the Nginx app)
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
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
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
