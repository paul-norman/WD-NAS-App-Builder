#!/bin/sh
# Runs Radicale (calendars and contacts: CalDAV and CardDAV) as its own user, with its data in the persistent path
# (Nas_Prog/_radicale - kept across reinstalls). The Nginx app serves it at https://calendar.<its domain> - by default
# (LISTEN=local, when the Nginx app is installed) only that way: Radicale then listens on the NAS itself only
# (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:5232 on the local network. Its users (added on the app's
# page) each have their own calendars and contacts, plus the Family calendar and address book every user shares:
#   radicale_ctl.sh setup   - create its user, folders, settings and the Family collections (where missing)
#   radicale_ctl.sh start   - start Radicale (on port 5232), checking that it's Radicale answering
#   radicale_ctl.sh stop    - stop Radicale
#   radicale_ctl.sh restart - stop, then start
#   radicale_ctl.sh users   - after the page changed the users: their folders, first collections and Family links
#   radicale_ctl.sh nginx   - rewrite the Nginx app's sites (Radicale's comes from its nginx.json), and reload it
#   radicale_ctl.sh daily   - keep its log small, and put back Family links removed from a phone
#
# Radicale reads its users file (users: name:SHA-512 crypt hash lines, written by the page) again whenever it changes,
# so adding or removing a user needs no restart.

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_radicale"
BIN="${APP_PATH}/binaries"
# Radicale's storage (its user's): collection-root/<user>/<collection>/ folders of .ics and .vcf files
COLLECTIONS="${DATA_PATH}/collections"
ROOT="${COLLECTIONS}/collection-root"
# The collections every user shares, linked into each user's own folder (as family-calendar and family-contacts), where
# their phones find them
FAMILY="${ROOT}/family"
USERS_FILE="${DATA_PATH}/users"
RIGHTS_FILE="${DATA_PATH}/rights"
CONFIG="${DATA_PATH}/config"
SETTINGS_FILE="${DATA_PATH}/settings"
OUT_LOG="${DATA_PATH}/radicale.out"
PID_FILE=/var/run/radicale.pid
PORT=5232
# Its own user and group (created if missing): the IDs used when creating them
RADICALE_ID=53
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') radicale/radicale_ctl.sh $*" >> ${LOG}
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

# Whether Radicale is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
radicale_ids() {
    awk -F: '$1 == "radicale" { print $3 " " $4 }' /etc/passwd
}

# Creates a collection (a calendar or an address book) where there's none, owned by Radicale's user.
#
# $1 folder The collection's folder
# $2 kind   VCALENDAR or VADDRESSBOOK
# $3 name   The name the phones show
#
# Returns 0 once it exists
new_collection() {
    local props

    [ -f "$1/.Radicale.props" ] && return 0

    if [ "$2" = VCALENDAR ]; then
        props="$(printf '{"tag": "VCALENDAR", "D:displayname": "%s", %s}' "$3" \
            '"C:supported-calendar-component-set": "VEVENT,VTODO,VJOURNAL"')"
    else
        props="{\"tag\": \"VADDRESSBOOK\", \"D:displayname\": \"$3\"}"
    fi

    mkdir -p "$1" && printf '%s\n' "${props}" > "$1/.Radicale.props" && chown -R "$(radicale_ids | tr ' ' ':')" "$1"
}

# Writes the access rules: every user has their own folder (and the collections in it), and the Family calendar and
# address book - nothing else (not other users' collections).
#
# Returns 0 once written
write_rights() {
    cat > "${RIGHTS_FILE}.tmp" <<'EOF'
# Written by the app (radicale_ctl.sh) at every start - changes here are lost
# The root: listed, so that phones can find each user's folder
[root]
user: .+
collection:
permissions: R

# Each user's own folder: its collections listed, new ones created
[principal]
user: .+
collection: {user}
permissions: RW

# Each user's own calendars and address books, and their links to the Family ones
[own]
user: .+
collection: {user}/[^/]+
permissions: rw

# The Family calendar and address book: every user's
[family]
user: .+
collection: family/(calendar|contacts)
permissions: rw
EOF
    mv -f "${RIGHTS_FILE}.tmp" "${RIGHTS_FILE}"
}

# Gives each user in the users file their folder: the first time, with their own calendar and address book; always, with
# links to the Family ones (put back if a phone removed them - removing one there removes only that user's link).
#
# Returns 0 once done
sync_users() {
    local name home

    [ -d "${ROOT}" ] || return 0

    sed -n 's/^\([a-z0-9][a-z0-9._-]*\):.*/\1/p' "${USERS_FILE}" 2>/dev/null | while read -r name; do
        [ "${name}" = family ] && continue
        home="${ROOT}/${name}"

        if [ ! -d "${home}" ]; then
            mkdir -p "${home}"
            new_collection "${home}/calendar" VCALENDAR 'Calendar'
            new_collection "${home}/contacts" VADDRESSBOOK 'Contacts'
            log "created ${name}'s folder, with their own calendar and contacts"
        fi

        [ -L "${home}/family-calendar" ] || ln -sfn ../family/calendar "${home}/family-calendar"
        [ -L "${home}/family-contacts" ] || ln -sfn ../family/contacts "${home}/family-contacts"
        chown -h "$(radicale_ids | tr ' ' ':')" "${home}" "${home}/family-calendar" "${home}/family-contacts"
    done
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^radicale:' /etc/group || addgroup -g ${RADICALE_ID} radicale
    grep -q '^radicale:' /etc/passwd \
        || adduser -D -H -h "${COLLECTIONS}" -s /bin/false -u ${RADICALE_ID} -G radicale radicale

    if [ -z "$(radicale_ids)" ]; then
        log "Could not create the radicale user (are ID ${RADICALE_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(radicale_ids)

    # Its folder: root's (settings, users, rights, config), passable for Radicale; the collections its user's
    mkdir -p "${ROOT}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${COLLECTIONS}" "${ROOT}"
    chmod 700 "${COLLECTIONS}"
    new_collection "${FAMILY}/calendar" VCALENDAR 'Family'
    new_collection "${FAMILY}/contacts" VADDRESSBOOK 'Family contacts'
    chown "$1:$2" "${FAMILY}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # Its users (none until the page adds them): Radicale reads them, the passwords hashed
    [ -f "${USERS_FILE}" ] || : > "${USERS_FILE}"
    chown "root:$2" "${USERS_FILE}"
    chmod 640 "${USERS_FILE}"

    write_rights
    chown "root:$2" "${RIGHTS_FILE}"
    chmod 640 "${RIGHTS_FILE}"
    sync_users

    touch "${OUT_LOG}"
    chmod 600 "${OUT_LOG}"
}

# Writes Radicale's settings: where it listens, its users and rights, its storage, and what it logs.
#
# Returns 0 once written
write_config() {
    local host=127.0.0.1

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0

    cat > "${CONFIG}" <<EOF
# Written by the app (radicale_ctl.sh) at every start - changes here are lost
[server]
hosts = ${host}:${PORT}

[auth]
type = htpasswd
htpasswd_filename = ${USERS_FILE}
htpasswd_encryption = autodetect
# (SHA-512 checks are slow in pure Python: each login is checked once, then remembered for a while)
cache_logins = True

[rights]
type = from_file
file = ${RIGHTS_FILE}

[storage]
filesystem_folder = ${COLLECTIONS}

[web]
type = internal

[logging]
level = warning
EOF
    chown "root:$(radicale_ids | cut -d ' ' -f 2)" "${CONFIG}"
    chmod 640 "${CONFIG}"
}

# Whether it's Radicale answering (its web interface), while it's still running - not something else on the port.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 120 ]; do
        running || return 1
        curl -s -m 3 "http://127.0.0.1:${PORT}/.web/" 2>/dev/null | grep -q 'Radicale' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running; then
        log "Radicale is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    write_config || return 1

    set -- $(radicale_ids)
    log "starting Radicale on port ${PORT} (LISTEN=$(setting LISTEN local))"
    cd "${COLLECTIONS}" || return 1
    ( HOME="${COLLECTIONS}" exec "${BIN}/radicale_runas" "$1" "$2" "${BIN}/python/bin/python3" -m radicale \
        -C "${CONFIG}" ) >> "${OUT_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Radicale did not start (see ${OUT_LOG}): $(tail -n 2 "${OUT_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Radicale started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Radicale (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Radicale did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# The Nginx app finds Radicale by its folder (its nginx.json): rewrite its sites
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"
    local php

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
            && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its output log under 1MB.
#
# Returns 0
rotate_log() {
    if [ "$(wc -c < "${OUT_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${OUT_LOG}" "${OUT_LOG}.1" && : > "${OUT_LOG}"
        chmod 600 "${OUT_LOG}.1"
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
    users) sync_users ;;
    nginx) nginx_site ;;
    daily)
        rotate_log
        sync_users
        ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|users|nginx|daily" >&2

        exit 1
        ;;
esac
