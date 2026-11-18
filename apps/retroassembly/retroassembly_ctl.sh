#!/bin/sh
# Runs RetroAssembly (a retro game library, played in the browser) as its own user, with its data in the persistent
# path Nas_Prog/_retroassembly - kept across reinstalls:
#   retroassembly_ctl.sh setup        - create its user, folders, settings and admin password (where missing)
#   retroassembly_ctl.sh start        - start it (on port 8098), checking that it answers; the first time, its admin
#                                       account is made first, with the sample games in its library
#   retroassembly_ctl.sh stop         - stop RetroAssembly
#   retroassembly_ctl.sh restart      - stop, then start
#   retroassembly_ctl.sh new-password - give the admin account a new password (signing it out everywhere)
#   retroassembly_ctl.sh set-password - the same, with the password typed on the page (on its input, one line)
#   retroassembly_ctl.sh backup       - back up its database (safely, while it runs), saves and screenshots
#   retroassembly_ctl.sh daily        - the daily job: a backup, and keeping its log small
#   retroassembly_ctl.sh nginx        - rewrite the Nginx app's sites (RetroAssembly's own comes from its nginx.json),
#                                       and reload it
#
# Nobody else can claim it: RetroAssembly lets anyone who can reach it make an account, and its first account is its
# admin - so the app's build only allows sign-ups when the app says so. Its first start only listens on the NAS itself,
# with sign-ups allowed just long enough for the app to make the admin account (and add the sample games). After that,
# sign-ups are off (the page's setting): the admin adds other people's accounts in RetroAssembly (Settings, Accounts)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_retroassembly"
# The NAS's PHP finds the Nginx app's site: wherever it is, also with a minimal PATH (e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
# RetroAssembly itself (it runs from its own folder: its web interface and database changes are found there)
RA_APP="${BIN}/retroassembly"
# Its database and storage - games, saves, screenshots (its user's only) - and its temporary files, on the same disk
# (the NAS's /tmp is in memory)
RA_DATA="${DATA_PATH}/data"
RA_STORAGE="${RA_DATA}/storage"
RA_TMP="${DATA_PATH}/tmp"
DATABASE="${RA_DATA}/retroassembly.sqlite"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
# Made once the admin account exists
CLAIMED="${DATA_PATH}/admin_created"
RA_LOG="${DATA_PATH}/retroassembly.log"
PID_FILE=/var/run/retroassembly.pid
PORT=8098
ADMIN_USER='admin'
# Its own user and group (created if missing): the IDs used when creating them
RA_ID=54
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') retroassembly/retroassembly_ctl.sh $*" >> ${LOG}
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

# Whether RetroAssembly is running (its PID file's process: a number, written since the NAS started).
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
# Prints them (e.g. 54 54), or nothing if there's no such user
ra_ids() {
    awk -F: '$1 == "retroassembly" { print $3 " " $4 }' /etc/passwd
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

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings and the
# admin password.
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^retroassembly:' /etc/group || addgroup -g ${RA_ID} retroassembly
    grep -q '^retroassembly:' /etc/passwd \
        || adduser -D -H -h /nonexistent -s /bin/false -u ${RA_ID} -G retroassembly retroassembly

    if [ -z "$(ra_ids)" ]; then
        log "Could not create the retroassembly user (are ID ${RA_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(ra_ids)

    # Its data and temporary files belong to its user; the settings and the password to root
    mkdir -p "${RA_STORAGE}" "${RA_TMP}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${RA_DATA}" "${RA_TMP}"
    chmod 700 "${RA_DATA}" "${RA_TMP}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nSIGNUPS=off\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_secret "${PASSWORD_FILE}" 20
    chmod 600 "${PASSWORD_FILE}"
    touch "${RA_LOG}"
    chmod 600 "${RA_LOG}"
}

# Runs a program as RetroAssembly's own user, in its folder, with its settings in its environment - in place of the
# current shell, so it's only called in a subshell.
#
# $1 host    The address it listens on (127.0.0.1 or 0.0.0.0)
# $2 signups Whether people may sign themselves up (on or off)
# $@         The program and its arguments
#
# Doesn't return
run_as_ra() {
    local host="$1"
    local signups="$2"

    shift 2
    set -- $(ra_ids) "$@"
    cd "${RA_APP}" || exit 1
    exec env HOME="${RA_DATA}" TMPDIR="${RA_TMP}" NODE_ENV=production \
        RETROASSEMBLY_NAS_HOST="${host}" \
        RETROASSEMBLY_NAS_SIGNUPS="${signups}" \
        RETROASSEMBLY_RUN_TIME_PORT="${PORT}" \
        RETROASSEMBLY_RUN_TIME_DATA_DIRECTORY="${RA_DATA}" \
        RETROASSEMBLY_RUN_TIME_STORAGE_DIRECTORY="${RA_STORAGE}" \
        "${BIN}/retroassembly_runas" "$@"
}

# Starts RetroAssembly's web server in the background (its output in its log).
#
# $1 host    The address it listens on (127.0.0.1 or 0.0.0.0)
# $2 signups Whether people may sign themselves up (on or off)
#
# Prints nothing; returns 0 once started
launch() {
    ( run_as_ra "$1" "$2" "${BIN}/node" --no-experimental-webstorage dist/server/serve.js ) >> "${RA_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
}

# Waits (up to 90 seconds - its first start creates the database) for RetroAssembly to answer, while it's still
# running.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 90 ]; do
        running || return 1
        curl -s -m 2 "http://127.0.0.1:${PORT}/login" 2>/dev/null | grep -q 'RetroAssembly' && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Adds the sample games (binaries/samples, listed in samples.tsv) to the library of the account signed in with the
# given cookies - each uploaded as RetroAssembly's own page does, then given its name, author and license.
#
# $1 cookies The cookie file of a session
#
# Prints what it did; returns 0 (a game that isn't added is logged, and left out)
add_samples() {
    local cookies="$1"
    local file platform name author license project rom id code about

    while IFS="$(printf '\t')" read -r file platform name author license project; do
        [ -f "${BIN}/samples/${file}" ] || continue
        rom="$(curl -s -m 120 -b "${cookies}" -F "file=@${BIN}/samples/${file}" -F "platform=${platform}" \
            "http://127.0.0.1:${PORT}/api/v1/roms")"
        id="$(printf '%s' "${rom}" | php "${APP_PATH}/lib/retroassembly.php" id)"

        if [ -z "${id}" ]; then
            log "the sample game ${name} was not added: $(printf '%s' "${rom}" | head -c 200)"
            continue
        fi

        about="Homebrew by ${author}, free to share (${license}): ${project}."
        about="${about} A sample game the NAS app added - delete it from its menu whenever you like."
        code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' -b "${cookies}" -X PATCH \
            --data-urlencode "gameName=${name}" --data-urlencode "gameDeveloper=${author}" \
            --data-urlencode "gameDescription=${about}" "http://127.0.0.1:${PORT}/api/v1/roms/${id}")"

        if [ "${code}" != 200 ]; then
            log "the sample game ${name} was added without its details (RetroAssembly answered ${code})"
            continue
        fi

        log "added the sample game: ${name} (${platform})"
    done < "${BIN}/samples/samples.tsv"
}

# Makes the admin account, the first time: RetroAssembly started on the NAS itself only, with sign-ups allowed, the
# account signed up through its API and given the sample games, then RetroAssembly stopped again. A database that
# already has accounts (e.g. its marker was lost) is left as it is.
#
# Prints what it did; returns 0 once the admin account exists
claim() {
    local users code
    local cookies="${RA_TMP}/claim-cookies"

    # (Only an existing database: sqlite3 would make an empty one - root's, which RetroAssembly then couldn't use)
    if [ -f "${DATABASE}" ]; then
        users="$("${BIN}/sqlite3" -readonly "${DATABASE}" 'SELECT count(*) FROM users WHERE status = 1;' 2>/dev/null)"
    fi

    if [ "${users:-0}" -gt 0 ]; then
        log "RetroAssembly already has ${users} account(s): no admin account made"
        touch "${CLAIMED}"

        return 0
    fi

    log 'first start: making the admin account (RetroAssembly only on the NAS itself meanwhile)'
    launch 127.0.0.1 on

    if ! wait_up; then
        log "RetroAssembly did not start (see ${RA_LOG}): $(tail -n 3 "${RA_LOG}" 2>/dev/null | tr '\n' ' ')"
        stop

        return 1
    fi

    rm -f "${cookies}"
    code="$(curl -s -m 60 -o /dev/null -w '%{http_code}' -c "${cookies}" --data-urlencode "username=${ADMIN_USER}" \
        --data-urlencode "password@${PASSWORD_FILE}" "http://127.0.0.1:${PORT}/api/v1/auth/register")"

    if [ "${code}" != 200 ]; then
        stop
        rm -f "${cookies}"
        log "Could not make the admin account (RetroAssembly answered ${code})"

        return 1
    fi

    touch "${CLAIMED}"
    log "made the admin account: ${ADMIN_USER}"
    add_samples "${cookies}"
    rm -f "${cookies}"
    stop
}

# Starts it as its own user, on the NAS itself or on every address - after making the admin account, the first time.
#
# Prints what it did; returns 0 once it answers
start() {
    local host=127.0.0.1

    if running; then
        log "RetroAssembly is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    if [ ! -f "${CLAIMED}" ]; then
        claim || return 1
    fi

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting RetroAssembly on ${host}:${PORT}, sign-ups $(setting SIGNUPS off) (log: ${RA_LOG})"
    launch "${host}" "$(setting SIGNUPS off)"

    if ! wait_up; then
        log "RetroAssembly did not start (see ${RA_LOG}): $(tail -n 3 "${RA_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "RetroAssembly started with PID: $(cat ${PID_FILE})"
}

# Stops it: politely first, then (after 20 seconds) by force.
#
# Prints what it did; returns 0 once stopped
stop() {
    local pid
    local waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping RetroAssembly (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'RetroAssembly did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Gives the admin account a new password (letters and digits), written straight into RetroAssembly's database as it
# writes them (lib/ra_password.mjs) - signing the account out everywhere. Works whether RetroAssembly runs or not.
#
# Prints what it did; returns 0 once set
new_password() {
    local password="${1:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)}"
    local output

    if [ ! -f "${DATABASE}" ]; then
        log 'RetroAssembly has no database yet: start it first'

        return 1
    fi

    if ! output="$(printf '%s' "${password}" | ( run_as_ra 127.0.0.1 off "${BIN}/node" \
        "${APP_PATH}/lib/ra_password.mjs" "${RA_APP}" "${DATABASE}" "${ADMIN_USER}" ) 2>&1)"; then
        log "Could not set a new admin password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s' "${password}" > "${PASSWORD_FILE}" )
    log 'set a new admin password'
}

# A new password from the page: the one on the input (one line - any visible characters), used as new_password uses a
# generated one.
#
# Returns 0 once it's in use
set_password() {
    local password

    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[[:cntrl:]]*) log 'Passwords are visible characters only (no control characters)'; return 1 ;;
    esac

    new_password "${password}"
}

# Backs up its database (SQLite's online backup: a consistent copy while RetroAssembly writes to it, checked) and the
# rest of its storage but the games themselves (saves, states, screenshots, covers...), as one .tar.gz in
# Nas_Prog/_retroassembly/backups - root's only - keeping the newest ones. The games are left out: they can be large,
# and you have them already.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    local work="${dir}/.retroassembly-${stamp}"
    local file="${dir}/retroassembly-${stamp}.tar.gz"
    local item

    if [ ! -f "${DATABASE}" ]; then
        log 'Nothing to back up yet (no database - RetroAssembly has not started yet)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1
    rm -rf "${work}"
    mkdir -m 700 "${work}" "${work}/storage" || return 1

    if ! "${BIN}/sqlite3" "${DATABASE}" ".backup '${work}/retroassembly.sqlite'" \
        || [ "$("${BIN}/sqlite3" "${work}/retroassembly.sqlite" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    for item in "${RA_STORAGE}"/* "${RA_STORAGE}"/.[!.]*; do
        [ -e "${item}" ] || continue
        [ "$(basename "${item}")" = roms ] || cp -a "${item}" "${work}/storage/"
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
    ls -1 "${dir}"/retroassembly-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' \
        | while read -r item; do
            rm -f "${item}"
        done
}

# Keeps its log under 1MB (the previous part is kept as retroassembly.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${RA_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${RA_LOG}" "${RA_LOG}.1" && : > "${RA_LOG}"
        chmod 600 "${RA_LOG}.1"
    fi

    return 0
}

# The Nginx app finds RetroAssembly by its folder (its nginx.json) and serves it at https://games.<its domain>: rewrite
# its sites, and reload it.
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
    set-password) set_password ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|set-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
