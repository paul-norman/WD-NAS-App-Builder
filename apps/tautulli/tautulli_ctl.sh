#!/bin/sh
# Runs Tautulli (statistics, history and notifications for Plex Media Server) as its own user, with its data in the
# persistent path (Nas_Prog/_tautulli - kept across reinstalls). The Nginx app serves it at https://tautulli.<its domain>
# - by default (LISTEN=local, when the Nginx app is installed) only that way: Tautulli then listens on the NAS itself
# only (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:8181 on the local network. It asks for a login (admin,
# with a password the app generates - set before its first start, so it's never open):
#   tautulli_ctl.sh setup        - create its user, folders, settings and first password (where missing)
#   tautulli_ctl.sh start        - start Tautulli (on port 8181), checking that it's Tautulli answering
#   tautulli_ctl.sh stop         - stop Tautulli
#   tautulli_ctl.sh restart      - stop, then start
#   tautulli_ctl.sh set-password - a new password for its admin login, read from the input (one line); restarts it
#   tautulli_ctl.sh nginx        - rewrite the Nginx app's sites (Tautulli's comes from its nginx.json), and reload it
#   tautulli_ctl.sh daily        - keep its output log small
#
# Its own settings (data/config.ini) are Tautulli's: the app only sets, at every start, where it listens and that it
# doesn't check GitHub for updates (the Store updates it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_tautulli"
BIN="${APP_PATH}/binaries"
# Tautulli's own folder (its settings, database, logs, backups and cache): its user's
TAUTULLI_DATA="${DATA_PATH}/data"
CONFIG="${TAUTULLI_DATA}/config.ini"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
OUT_LOG="${DATA_PATH}/tautulli.out"
PID_FILE=/var/run/tautulli.pid
PORT=8181
# The user name of its login
AUTH_USER=admin
# Its own user and group (created if missing): the IDs used when creating them
TAUTULLI_ID=93
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') tautulli/tautulli_ctl.sh $*" >> ${LOG}
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

# Whether Tautulli is running (its PID file's process - the same one after Tautulli restarts itself).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
tautulli_ids() {
    awk -F: '$1 == "tautulli" { print $3 " " $4 }' /etc/passwd
}

# Sets one of Tautulli's settings in its [General] section (adding it if it's missing), while Tautulli isn't running -
# it writes its settings back when it stops.
#
# $1 key   The setting, as config.ini has it (e.g. http_host)
# $2 value Its value
#
# Returns 0 once it's written
set_config() {
    awk -v key="$1" -v value="$2" '
        /^\[/ { if (section == "General" && !done) { print key " = " value; done = 1 } section = substr($0, 2, length($0) - 2) }
        section == "General" && $1 == key && $2 == "=" { if (!done) { print key " = " value; done = 1 } next }
        { print }
        END { if (!done) { if (section != "General") print "[General]"; print key " = " value } }
    ' "${CONFIG}" > "${CONFIG}.tmp" && cat "${CONFIG}.tmp" > "${CONFIG}" && rm -f "${CONFIG}.tmp"
}

# Hashes a password as Tautulli does (with its own code), for its settings.
#
# Prints the hash (the password is read from the input)
hash_password() {
    "${BIN}/python/bin/python3" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from hashing_passwords import make_hash
print(make_hash(sys.stdin.read()))' "${BIN}/tautulli/lib"
}

# A new password for Tautulli's admin login (from the input), kept for the page (root's only) and set in Tautulli's
# settings, hashed. Tautulli is restarted if it was running.
#
# Returns 0 once it's set
set_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    hash="$(printf '%s' "${password}" | hash_password)"

    case "${hash}" in
        PBKDF2\$*) ;;
        *) log "Could not hash the password: ${hash}"; return 1 ;;
    esac

    was_running=0

    if running; then
        was_running=1
        stop
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}" || return 1
    set_config http_username "${AUTH_USER}" && set_config http_password "${hash}" && set_config http_hashed_password 1 \
        || return 1
    log 'a new password was set for its login'

    if [ ${was_running} = 1 ]; then
        start
    fi
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^tautulli:' /etc/group || addgroup -g ${TAUTULLI_ID} tautulli
    grep -q '^tautulli:' /etc/passwd || adduser -D -H -h "${TAUTULLI_DATA}" -s /bin/false -u ${TAUTULLI_ID} -G tautulli tautulli

    if [ -z "$(tautulli_ids)" ]; then
        log "Could not create the tautulli user (are ID ${TAUTULLI_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(tautulli_ids)

    # Its folder: root's (the settings and password), passable for Tautulli; Tautulli's own data its user's
    mkdir -p "${TAUTULLI_DATA}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${TAUTULLI_DATA}"
    chmod 700 "${TAUTULLI_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # Its first settings, before it ever starts: its login (the password as given - Tautulli hashes it at its first
    # start), no browser to open, behind a proxy (the Nginx app)
    if [ ! -f "${CONFIG}" ]; then
        password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}" )
        printf '[General]\nhttp_port = %s\nhttp_username = %s\nhttp_password = %s\nhttp_hashed_password = 0\nlaunch_browser = 0\nhttp_proxy = 1\n' \
            "${PORT}" "${AUTH_USER}" "${password}" > "${CONFIG}"
        chown "$1:$2" "${CONFIG}"
        chmod 600 "${CONFIG}"
        log "created its first settings, with a password for its login (shown on the app's page)"
    fi

    touch "${OUT_LOG}"
    chmod 600 "${OUT_LOG}"
}

# Whether it's Tautulli answering (its login page), while it's still running - not something else on the port. Its first
# start creates its database, which takes a while on the NAS.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 120 ]; do
        running || return 1
        curl -s -m 3 "http://127.0.0.1:${PORT}/auth/login" 2>/dev/null | grep -q '<title>Tautulli' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running; then
        log "Tautulli is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    # Where it listens, and no update checks (they'd offer an update it can't install: the Store updates it)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    set_config http_host "${host}" && set_config http_port "${PORT}" && set_config check_github 0 \
        && set_config check_github_on_startup 0 || return 1

    set -- $(tautulli_ids)
    log "starting Tautulli on ${host}:${PORT}"
    # --nofork: Tautulli restarts itself (e.g. after some settings change) in the same process
    cd "${TAUTULLI_DATA}" || return 1
    ( HOME="${TAUTULLI_DATA}" exec "${BIN}/tautulli_runas" "$1" "$2" "${BIN}/python/bin/python3" \
        "${BIN}/tautulli/Tautulli.py" --datadir "${TAUTULLI_DATA}" --config "${CONFIG}" --nolaunch --nofork \
        --quiet ) >> "${OUT_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Tautulli did not start (see ${OUT_LOG} and ${TAUTULLI_DATA}/logs): $(tail -n 2 "${OUT_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Tautulli started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Tautulli (PID ${pid})"
        kill "${pid}"
        # It writes its settings and finishes its database work first
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log 'Tautulli did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# The Nginx app finds Tautulli by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

# Keeps its output log under 1MB (Tautulli keeps its own logs, in data/logs)
rotate_log() {
    if [ "$(wc -c < "${OUT_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${OUT_LOG}" "${OUT_LOG}.1" && : > "${OUT_LOG}"
        chmod 600 "${OUT_LOG}.1"
    fi
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    set-password) set_password ;;
    nginx) nginx_site ;;
    daily) rotate_log ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|nginx|daily" >&2

        exit 1
        ;;
esac
