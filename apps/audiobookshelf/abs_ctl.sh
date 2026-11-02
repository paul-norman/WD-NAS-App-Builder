#!/bin/sh
# Runs Audiobookshelf (audiobooks and podcasts) as its own user, with its data in the persistent path
# Nas_Prog/_audiobookshelf - kept across reinstalls:
#   abs_ctl.sh setup                - create its user, folders and settings (where missing)
#   abs_ctl.sh start                - start it (on port 13378: the network, or the NAS itself only). The first time, the
#                                     app claims its root user (with a generated password) before anyone else can
#   abs_ctl.sh stop                 - stop Audiobookshelf
#   abs_ctl.sh restart              - stop, then start
#   abs_ctl.sh new-password         - give the root user a new (generated) password, while Audiobookshelf runs
#   abs_ctl.sh check-folder <path>  - whether Audiobookshelf's user can read and write a folder (exit status 0: both, 1:
#                                     read only, 2: neither)
#   abs_ctl.sh daily                - the daily job: keeping its log small
#   abs_ctl.sh nginx                - add / update Audiobookshelf's site in the Nginx app (and reload it)
#
# Its user's group is the NAS's share group (which every NAS user is in): what it writes into the shares (podcast
# episodes, merged audiobooks, metadata files if turned on) can be changed over SMB too. Audiobookshelf backs its own
# database up every night (to metadata/backups)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_audiobookshelf"
# PHP finds the Nginx app's address: wherever it is, also when run with a minimal PATH, e.g. from the management page
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
CONFIG_DIR="${DATA_PATH}/config"
METADATA_DIR="${DATA_PATH}/metadata"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/root_password"
ABS_LOG="${DATA_PATH}/audiobookshelf.log"
PID_FILE=/var/run/audiobookshelf.pid
PORT=13378
ROOT_USER=root
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
ABS_ID=83
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') audiobookshelf/abs_ctl.sh $*" >> ${LOG}
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

abs_ids() {
    awk -F: '$1 == "audiobookshelf" { print $3 " " $4 }' /etc/passwd
}

random_text() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^audiobookshelf:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=audiobookshelf
            grep -q '^audiobookshelf:' /etc/group || addgroup -g ${ABS_ID} audiobookshelf
        fi
        adduser -D -H -h /nonexistent -s /bin/false -u ${ABS_ID} -G ${group} audiobookshelf
    fi

    if [ -z "$(abs_ids)" ]; then
        log "Could not create the audiobookshelf user (is ID ${ABS_ID} already taken?)"

        return 1
    fi

    set -- $(abs_ids)

    # Its database (config) and covers, cache, logs and backups (metadata) belong to its user; the page's settings and
    # the root password to root
    mkdir -p "${CONFIG_DIR}" "${METADATA_DIR}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${CONFIG_DIR}" "${METADATA_DIR}"
    chmod 700 "${CONFIG_DIR}" "${METADATA_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        printf 'LISTEN=all\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${ABS_LOG}"
    chmod 600 "${ABS_LOG}"
}

# Starts it, answering on $1 (an address to listen on)
launch() {
    set -- $(abs_ids) "$1"

    # Podcast feeds on the home network (host names, e.g. a podcast server of its own): Audiobookshelf refuses private
    # addresses otherwise (protection against requests to the NAS's own services)
    allowed="$(setting LOCAL_FEEDS '' | tr -cd 'A-Za-z0-9.,-')"

    cd "${BIN}/app" || return 1

    # Its binaries are the app's: no checks for, or downloads of, its own
    ( exec env NODE_ENV=production PORT=${PORT} HOST="$3" CONFIG_PATH="${CONFIG_DIR}" METADATA_PATH="${METADATA_DIR}" \
        SOURCE=debian SKIP_BINARIES_CHECK=1 FFMPEG_PATH="${BIN}/ffmpeg" FFPROBE_PATH="${BIN}/ffprobe" \
        NUSQLITE3_PATH="${BIN}/libnusqlite3.so" TZ="$(cat /etc/TZ 2>/dev/null)" SSRF_REQUEST_FILTER_WHITELIST="${allowed}" \
        "${BIN}/abs_runas" "$1" "$2" "${BIN}/node/bin/node" dist-server/index.js ) >> "${ABS_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
}

# Waits up to 90 seconds for Audiobookshelf to answer (the first start creates its database)
wait_up() {
    waited=0

    while [ ${waited} -lt 90 ]; do
        curl -sf -o /dev/null "http://127.0.0.1:${PORT}/status" && return 0
        running || return 1
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Whether it has its root user yet
initialised() {
    curl -sf "http://127.0.0.1:${PORT}/status" | grep -q '"isInit":true'
}

start() {
    if running; then
        log "Audiobookshelf is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    host=0.0.0.0
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1

    # The password file exists once the root user does: empty if it was made elsewhere, e.g. data from another install
    if [ ! -f "${PASSWORD_FILE}" ]; then
        # The first time: only on the NAS itself until the app has claimed the root user, so that no one else can (its
        # setup page lets the first visitor choose the root password)
        log 'starting Audiobookshelf for the first time (on the NAS itself only, to create its root user)'
        launch 127.0.0.1

        if ! wait_up; then
            log "Audiobookshelf did not answer within 90 seconds (see ${ABS_LOG})"
            stop

            return 1
        fi

        if ! initialised; then
            password="$(random_text 20)"

            if curl -sf -o /dev/null -X POST -H 'Content-Type: application/json' \
                -d "{\"newRoot\":{\"username\":\"${ROOT_USER}\",\"password\":\"${password}\"}}" "http://127.0.0.1:${PORT}/init"; then
                ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}" )
                log "created the root user (${ROOT_USER}) with a generated password"
            else
                log "Could not create Audiobookshelf's root user"
                stop

                return 1
            fi
        else
            log "Audiobookshelf already has a root user, made elsewhere: its password isn't known to the app"
            ( umask 077; : > "${PASSWORD_FILE}" )
        fi

        stop
    fi

    log "starting Audiobookshelf on port ${PORT} (log: ${ABS_LOG})"
    launch "${host}"

    if ! wait_up; then
        log "Audiobookshelf did not answer within 90 seconds (see ${ABS_LOG})"

        return 1
    fi

    log "Audiobookshelf started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Audiobookshelf (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Audiobookshelf did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# A new generated password for the root user, through Audiobookshelf's own API (logged in with the current one)
new_password() {
    old="$(cat "${PASSWORD_FILE}" 2>/dev/null)"
    password="$(random_text 20)"
    token="$(curl -sf -X POST -H 'Content-Type: application/json' -d "{\"username\":\"${ROOT_USER}\",\"password\":\"${old}\"}" \
        "http://127.0.0.1:${PORT}/login" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')"

    if [ -z "${token}" ]; then
        log "Could not log in as ${ROOT_USER} (was its password changed in Audiobookshelf?)"

        return 1
    fi

    if curl -sf -o /dev/null -X PATCH -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
        -d "{\"password\":\"${old}\",\"newPassword\":\"${password}\"}" "http://127.0.0.1:${PORT}/api/me/password"; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
        log "gave the root user (${ROOT_USER}) a new password"
    else
        log "Could not change the root user's password"

        return 1
    fi
}

check_folder() {
    set -- $(abs_ids) "$1"
    [ -d "$3" ] && "${BIN}/abs_runas" "$1" "$2" /bin/ls "$3" > /dev/null 2>&1 || return 2
    "${BIN}/abs_runas" "$1" "$2" /bin/sh -c 'test -w "$1" && test -x "$1"' sh "$3" || return 1
}

# Keeps its log under 5MB (the previous part is kept as audiobookshelf.log.1). Audiobookshelf keeps its own detailed
# logs too, in metadata/logs
rotate_log() {
    if [ "$(wc -c < "${ABS_LOG}" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        cp "${ABS_LOG}" "${ABS_LOG}.1" && : > "${ABS_LOG}"
        chmod 600 "${ABS_LOG}.1"
    fi
}

# The Nginx app finds Audiobookshelf by its folder and serves it at https://audiobooks.<its domain>: rewrite its sites
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
    check-folder) setup > /dev/null && check_folder "$2" ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|check-folder <path>|daily|nginx" >&2

        exit 1
        ;;
esac
