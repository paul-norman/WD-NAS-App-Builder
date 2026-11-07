#!/bin/sh
# Runs rclone (cloud storage sync) as its own user, in the NAS's share group, with its data in the persistent path
# Nas_Prog/_rclone - kept across reinstalls: its web interface (its remote control server, rcd, serving the interface and
# the API it calls on one port, 5572) and the page's jobs. Run by the app's scripts, its management page and cron:
#   rclone_ctl.sh setup        - create its user, folders and web interface password (where missing)
#   rclone_ctl.sh start        - start its web interface
#   rclone_ctl.sh stop         - stop it
#   rclone_ctl.sh restart      - stop, then start
#   rclone_ctl.sh new-password - generate a new web interface password (applied when it next starts)
#   rclone_ctl.sh run <id>     - run a job now (waits for it; a job already running isn't started again)
#   rclone_ctl.sh due          - hourly (from root's crontab): run the jobs set for this hour, one after another
#   rclone_ctl.sh daily        - the daily job: keeping its log small
#   rclone_ctl.sh nginx        - add / update rclone's site in the Nginx app (and reload it)
#
# What it writes in the shares belongs to the share group and stays writable by it (its helper's umask), so the NAS's
# users can change it over SMB

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_rclone"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
CONF="${DATA_PATH}/config/rclone.conf"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
HTPASSWD="${DATA_PATH}/htpasswd"
STATUS_DIR="${DATA_PATH}/status"
RCLONE_LOG="${DATA_PATH}/rclone.log"
PID_FILE=/var/run/rclone.pid
PORT=5572
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
RCLONE_ID=68
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') rclone/rclone_ctl.sh $*" >> ${LOG}
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

# Whether its web interface is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The rclone user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
rclone_ids() {
    awk -F: '$1 == "rclone" { print $3 " " $4 }' /etc/passwd
}

# Writes the web interface's login for rclone (user admin with the app's password, bcrypt - rclone checks it itself),
# readable by its user only.
#
# Returns 0 once it's written
write_htpasswd() {
    local hash

    set -- $(rclone_ids)
    hash="$(php -r 'echo password_hash(trim(fgets(STDIN)), PASSWORD_BCRYPT);' < "${PASSWORD_FILE}")"

    case "${hash}" in
        '$2'*) ;;
        *) log 'Could not hash the password (is PHP working?)'; return 1 ;;
    esac

    printf 'admin:%s\n' "${hash}" > "${HTPASSWD}.tmp" && chown "$1:$2" "${HTPASSWD}.tmp" && chmod 600 "${HTPASSWD}.tmp" \
        && mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

# Makes a new web interface password (letters and digits), root's only, and its login for rclone.
#
# Prints nothing
new_password() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    log 'generated a new web interface password'
    write_htpasswd
}

setup() {
    local group

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^rclone:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=rclone
            grep -q '^rclone:' /etc/group || addgroup -g ${RCLONE_ID} rclone
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${RCLONE_ID} -G ${group} rclone
    fi

    if [ -z "$(rclone_ids)" ]; then
        log "Could not create the rclone user (is ID ${RCLONE_ID} already taken?)"

        return 1
    fi

    set -- $(rclone_ids)

    # Its own data (its remotes - their keys and tokens - and its cache) belongs to its user; the page's settings, its
    # jobs, their results and the password to root
    mkdir -p "${DATA_PATH}/config" "${DATA_PATH}/cache" "${STATUS_DIR}"
    chmod 711 "${DATA_PATH}"
    touch "${CONF}"
    chown -R "$1:$2" "${DATA_PATH}/config" "${DATA_PATH}/cache"
    chmod 700 "${DATA_PATH}/config" "${DATA_PATH}/cache"
    chmod 600 "${CONF}"
    chmod 711 "${STATUS_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        printf 'LISTEN=all\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password

    # Its login for rclone (made again if the password is newer)
    if [ ! -s "${HTPASSWD}" ] || [ "${PASSWORD_FILE}" -nt "${HTPASSWD}" ]; then
        write_htpasswd
    fi

    touch "${RCLONE_LOG}"
    chmod 600 "${RCLONE_LOG}"
}

start() {
    local host=0.0.0.0

    if running; then
        log "rclone is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    set -- $(rclone_ids)
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1

    log "starting rclone's web interface on port ${PORT} (log: ${RCLONE_LOG})"
    cd "${DATA_PATH}/cache" || return 1
    # (rcd opens the interface in a browser when it serves one: its PATH's xdg-open does nothing - a NAS has no browser)
    ( exec env HOME="${DATA_PATH}/config" PATH="${APP_PATH}/nobrowser:/bin:/usr/bin" "${BIN}/rclone_runas" "$1" "$2" \
        "${BIN}/rclone" rcd --rc-files "${BIN}/gui" --rc-addr "${host}:${PORT}" --rc-htpasswd "${HTPASSWD}" \
        --config "${CONF}" --cache-dir "${DATA_PATH}/cache" --log-level NOTICE ) >> "${RCLONE_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "rclone started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping rclone (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${waited}" -ge 30 ]; then
                log 'rclone did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Writes a job's state (status/<id>.json, root's - read by the page).
#
# $1 id       The job's ID
# $2 state    running, ok or failed
# $3 started  When it started (seconds since 1970)
# $4 finished When it finished (seconds since 1970; 0 while running)
#
# Prints nothing
job_state() {
    printf '{"state": "%s", "started": %s, "finished": %s}\n' "$2" "$3" "$4" > "${STATUS_DIR}/$1.json.tmp" \
        && mv -f "${STATUS_DIR}/$1.json.tmp" "${STATUS_DIR}/$1.json"
}

# Runs a job as rclone's user: its mode (copy or sync), source and destination come from the page's jobs. Its log is
# status/<id>.log (its last run's). A job that's already running is left alone.
#
# $1 id The job's ID
#
# Returns rclone's exit code (1 if the job isn't there, or is already running)
run_job() {
    local id="$1" job mode source destination started code

    case "${id}" in
        *[!a-f0-9]* | '') log "Not a job: ${id}"; return 1 ;;
    esac

    job="$(php "${APP_PATH}/lib/rclone.php" job "${DATA_PATH}" "${id}")" || { log "No such job: ${id}"; return 1; }
    mode="$(echo "${job}" | sed -n 1p)"
    source="$(echo "${job}" | sed -n 2p)"
    destination="$(echo "${job}" | sed -n 3p)"
    setup > /dev/null || return 1

    # One run at a time (its lock goes when it's done, or with the next boot: /var/run is in RAM)
    if ! mkdir "/var/run/rclone-job-${id}" 2>/dev/null; then
        log "job ${id} is already running"

        return 1
    fi

    set -- $(rclone_ids)
    started="$(date +%s)"
    job_state "${id}" running "${started}" 0
    : > "${STATUS_DIR}/${id}.log"
    chown "$1:$2" "${STATUS_DIR}/${id}.log"
    chmod 600 "${STATUS_DIR}/${id}.log"
    log "running job ${id}: rclone ${mode} ${source} ${destination}"

    env HOME="${DATA_PATH}/config" "${BIN}/rclone_runas" "$1" "$2" "${BIN}/rclone" "${mode}" "${source}" "${destination}" \
        --config "${CONF}" --cache-dir "${DATA_PATH}/cache" --log-file "${STATUS_DIR}/${id}.log" --log-level INFO \
        --stats 1m --stats-one-line --stats-log-level NOTICE > /dev/null 2>&1
    code=$?

    if [ "${code}" = 0 ]; then
        job_state "${id}" ok "${started}" "$(date +%s)"
    else
        job_state "${id}" failed "${started}" "$(date +%s)"
        log "job ${id} failed (rclone's exit code ${code}; its log: ${STATUS_DIR}/${id}.log)"
    fi

    rmdir "/var/run/rclone-job-${id}"

    return "${code}"
}

# Runs the jobs set for this hour, one after another.
#
# Prints nothing
run_due() {
    local id

    for id in $(php "${APP_PATH}/lib/rclone.php" due "${DATA_PATH}" "$(date +%H | sed 's/^0//')"); do
        run_job "${id}" > /dev/null 2>&1
    done
}

# Keeps its log under 1MB (the previous part is kept as rclone.log.1).
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${RCLONE_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${RCLONE_LOG}" "${RCLONE_LOG}.1" && : > "${RCLONE_LOG}"
        chmod 600 "${RCLONE_LOG}.1"
    fi
}

# The Nginx app finds rclone by its folder and serves it at https://rclone.<its domain>: rewrite its sites.
#
# Prints nothing
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
    run) run_job "$2" ;;
    due) run_due ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|run <id>|due|daily|nginx" >&2

        exit 1
        ;;
esac
