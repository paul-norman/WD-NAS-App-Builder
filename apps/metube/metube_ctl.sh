#!/bin/sh
# Runs MeTube (downloads with yt-dlp) and the Watch page (each household member's own downloads, with a player and
# clean-up - watch/watch.py) as MeTube's own user, with their data in the persistent path (Nas_Prog/_metube - kept
# across reinstalls). MeTube only listens on the NAS itself (127.0.0.1:8085): its own page shows everyone's downloads,
# so only the Watch page uses it. The Nginx app serves the Watch page at https://videos.<its domain> - by default
# (listen: local, when the Nginx app is installed) only that way; with listen: all it's also at http://<nas-ip>:8086.
#   metube_ctl.sh setup   - create its user, folders and settings (where missing)
#   metube_ctl.sh start   - start MeTube, then the Watch page, checking that each answers
#   metube_ctl.sh stop    - stop both
#   metube_ctl.sh restart - stop, then start
#   metube_ctl.sh ytdlp   - the newest yt-dlp from PyPI (unless turned off on the page): installed beside the packaged
#                           one, checked, used from then on (MeTube restarted) - "force" checks even when turned off
#   metube_ctl.sh nginx   - rewrite the Nginx app's sites (the Watch page's comes from its nginx.json), and reload it
#   metube_ctl.sh daily   - keep its logs small
#
# Its settings (settings.json) and users (users.json) are written by its management page; the Watch page reads them
# again whenever they change.

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_metube"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
SETTINGS_FILE="${DATA_PATH}/settings.json"
USERS_FILE="${DATA_PATH}/users.json"
SECRET_FILE="${DATA_PATH}/secret"
# MeTube's own state (its queue and history), its downloads in progress, and the Watch page's state: its user's
STATE="${DATA_PATH}/state"
TEMP="${DATA_PATH}/temp"
WATCH_STATE="${DATA_PATH}/watch"
CACHE="${DATA_PATH}/cache"
# yt-dlp updated from PyPI (used before the packaged one, when it's there), and how its last update went
YTDLP="${DATA_PATH}/ytdlp"
YTDLP_STATUS="${DATA_PATH}/ytdlp.status"
METUBE_LOG="${DATA_PATH}/metube.log"
WATCH_LOG="${DATA_PATH}/watch.log"
PID_FILE=/var/run/metube.pid
WATCH_PID_FILE=/var/run/metube-watch.pid
METUBE_PORT=8085
WATCH_PORT=8086
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
METUBE_ID=52
# What yt-dlp writes beside each video: its thumbnail, as a JPEG (for the Watch page, Plex, Jellyfin and Emby)
YTDL_OPTIONS='{"writethumbnail": true, "postprocessors": [{"key": "FFmpegThumbnailsConvertor", "format": "jpg",'
YTDL_OPTIONS="${YTDL_OPTIONS} \"when\": \"before_dl\"}]}"
# Downloads named "Title [id]" (the Watch page shows the title, and looks YouTube videos up in SponsorBlock by the ID)
# - a playlist's or channel's videos in a folder of its own, numbered in its order: "<playlist>/001 - Title [id]"
OUTPUT_TEMPLATE='%(title)s [%(id)s].%(ext)s'
OUTPUT_TEMPLATE_PLAYLIST='%(playlist_title)s/%(playlist_index)03d - %(title)s [%(id)s].%(ext)s'
OUTPUT_TEMPLATE_CHANNEL='%(channel)s/%(channel_index)03d - %(title)s [%(id)s].%(ext)s'
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') metube/metube_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from settings.json (written by the management page).
#
# $1 name    The setting (e.g. download_dir)
# $2 default What to print if it isn't set
#
# Prints its value (true / false for yes-or-no settings), or the default
setting() {
    "${PYTHON}" -I -c 'import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2])
except (OSError, ValueError):
    value = None
if value is None or value == "":
    print(sys.argv[3])
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)' "${SETTINGS_FILE}" "$1" "$2" 2>/dev/null || echo "$2"
}

# Whether a process is running (its PID file's).
#
# $1 pid_file Its PID file
#
# Returns 0 if it is
running() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# MeTube's user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
metube_ids() {
    awk -F: '$1 == "metube" { print $3 " " $4 }' /etc/passwd
}

# Runs a program as MeTube's user, in the app's environment: its programs (ffmpeg) first on the PATH, the updated
# yt-dlp first for Python, files writable by the share group. Replaces the (background) shell it's called in, so that
# its PID is the program's.
#
# $@ The program and its arguments
as_metube() {
    set -- $(metube_ids) "$@"
    local uid="$1"
    local gid="$2"

    shift 2
    umask 002
    export HOME="${CACHE}" XDG_CACHE_HOME="${CACHE}" DENO_DIR="${CACHE}/deno" PATH="${BIN}/bin:/usr/bin:/bin" \
        PYTHONPATH="$([ -d "${YTDLP}" ] && echo "${YTDLP}")"
    exec "${BIN}/metube_runas" "${uid}" "${gid}" - "$@"
}

setup() {
    local group download

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^metube:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=metube
            grep -q '^metube:' /etc/group || addgroup -g ${METUBE_ID} metube
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${METUBE_ID} -G ${group} metube
    fi

    if [ -z "$(metube_ids)" ]; then
        log "Could not create the metube user (is ID ${METUBE_ID} already taken?)"

        return 1
    fi

    set -- $(metube_ids)

    # Its folder: root's, passable; its state its user's
    mkdir -p "${STATE}" "${TEMP}" "${WATCH_STATE}" "${CACHE}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${STATE}" "${TEMP}" "${WATCH_STATE}" "${CACHE}"
    chmod 700 "${STATE}" "${TEMP}" "${WATCH_STATE}" "${CACHE}"
    [ -d "${YTDLP}" ] && chown -R "$1:$2" "${YTDLP}"

    # What the Watch page signs its sessions with
    if [ ! -s "${SECRET_FILE}" ]; then
        ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 > "${SECRET_FILE}" )
    fi

    # Its first settings: downloads into Public/Watch Later (when there's a Public share), only through the Nginx app
    # when it's installed, yt-dlp updated every night, videos cleaned up 3 days after watched (30 if never)
    if [ ! -f "${SETTINGS_FILE}" ]; then
        download=''
        [ -d /mnt/HD/HD_a2/Public ] && download='/mnt/HD/HD_a2/Public/Watch Later'
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        "${PYTHON}" -I -c 'import json, sys
json.dump({"download_dir": sys.argv[2], "listen": sys.argv[3], "ytdlp_update": True, "watched_days": 3,
           "unwatched_days": 30, "media_server": {}}, open(sys.argv[1], "w"), indent=2)' \
            "${SETTINGS_FILE}" "${download}" "${listen}"
        log "created its first settings (download folder: ${download:-none}, listen: ${listen})"
    fi

    [ -f "${USERS_FILE}" ] || printf '{"users": {}}\n' > "${USERS_FILE}"

    # Root's, readable by its user only
    chown "$1:root" "${SECRET_FILE}" "${SETTINGS_FILE}" "${USERS_FILE}"
    chmod 400 "${SECRET_FILE}"
    chmod 640 "${SETTINGS_FILE}" "${USERS_FILE}"

    # The download folder, writable by its user and the share group (each person's folder is made by MeTube in it)
    download="$(setting download_dir '')"

    if [ -n "${download}" ]; then
        mkdir -p "${download}"
        chown "$1:$2" "${download}"
        chmod 2775 "${download}"
    fi

    touch "${METUBE_LOG}" "${WATCH_LOG}"
    chmod 600 "${METUBE_LOG}" "${WATCH_LOG}"
}

# Waits until something answers at an address with the expected text, while its process still runs.
#
# $1 pid_file Its PID file
# $2 url      The address
# $3 text     What its answer contains
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 120 ]; do
        running "$1" || return 1
        curl -s -m 3 "$2" 2>/dev/null | grep -q "$3" && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start_metube() {
    local download

    running "${PID_FILE}" && return 0
    download="$(setting download_dir '')"

    if [ -z "${download}" ]; then
        log 'No download folder is set (the app'"'"'s page): MeTube not started'

        return 1
    fi

    log "starting MeTube on 127.0.0.1:${METUBE_PORT} (downloads into ${download})"
    # (exported: a shell passes VAR=value before a function's name on to what it runs only if it wants to)
    ( cd "${BIN}/metube" || exit 1
    export DOWNLOAD_DIR="${download}" STATE_DIR="${STATE}" TEMP_DIR="${TEMP}" HOST=127.0.0.1 PORT=${METUBE_PORT} \
        YTDL_OPTIONS="${YTDL_OPTIONS}" CREATE_CUSTOM_DIRS=true CUSTOM_DIRS=true DELETE_FILE_ON_TRASHCAN=true \
        ALLOW_PRIVATE_ADDRESSES="${METUBE_ALLOW_PRIVATE:-false}" METUBE_VERSION="$(cat "${BIN}/version")" \
        OUTPUT_TEMPLATE="${OUTPUT_TEMPLATE}" OUTPUT_TEMPLATE_PLAYLIST="${OUTPUT_TEMPLATE_PLAYLIST}" \
        OUTPUT_TEMPLATE_CHANNEL="${OUTPUT_TEMPLATE_CHANNEL}"
    as_metube "${PYTHON}" app/main.py ) >> "${METUBE_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up "${PID_FILE}" "http://127.0.0.1:${METUBE_PORT}/version" 'version'; then
        log "MeTube did not start (see ${METUBE_LOG}): $(tail -n 2 "${METUBE_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "MeTube started with PID: $(cat ${PID_FILE})"
}

start_watch() {
    local host=127.0.0.1

    running "${WATCH_PID_FILE}" && return 0
    [ "$(setting listen local)" = all ] && host=0.0.0.0
    log "starting the Watch page on ${host}:${WATCH_PORT}"
    ( as_metube "${PYTHON}" "${APP_PATH}/watch/watch.py" --data "${DATA_PATH}" --static "${APP_PATH}/watch/static" \
        --host "${host}" --port ${WATCH_PORT} --metube "http://127.0.0.1:${METUBE_PORT}" ) >> "${WATCH_LOG}" 2>&1 &
    echo $! > "${WATCH_PID_FILE}"

    if ! wait_up "${WATCH_PID_FILE}" "http://127.0.0.1:${WATCH_PORT}/health" '"watch"'; then
        log "the Watch page did not start (see ${WATCH_LOG}): $(tail -n 2 "${WATCH_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "the Watch page started with PID: $(cat ${WATCH_PID_FILE})"
}

start() {
    local metube

    setup || return 1
    start_metube
    metube=$?
    # (the Watch page runs anyway: it says why downloads don't work)
    start_watch || return 1

    return ${metube}
}

# Stops a process (its PID file's), waiting for it, then killing it after 30 seconds.
#
# $1 pid_file Its PID file
# $2 name     Its name, for the log
stop_one() {
    local pid waited

    if running "$1"; then
        pid="$(cat "$1")"
        log "stopping $2 (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                log "$2 did not stop within 30 seconds, killing it"
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "$1"
}

stop() {
    stop_one "${WATCH_PID_FILE}" 'the Watch page'
    stop_one "${PID_FILE}" MeTube
}

# The version of yt-dlp Python finds first (with a given folder of packages first).
#
# $1 folder The folder ('' for the packaged one only)
#
# Prints the version, or nothing if it can't be imported
ytdlp_version() {
    PYTHONPATH="$1" "${PYTHON}" -c 'from yt_dlp.version import __version__; print(__version__)' 2>/dev/null
}

# Updates yt-dlp from PyPI into the data folder, checking that the new one imports and runs before using it; MeTube is
# restarted if it changed. Leaves the one in use if anything fails.
#
# $1 force "force" to check even when turned off on the page
#
# Returns 0 if it's up to date (or turned off)
update_ytdlp() {
    local now current new index

    if [ "$1" != force ] && [ "$(setting ytdlp_update true)" = false ]; then
        return 0
    fi

    setup > /dev/null || return 1
    set -- $(metube_ids)
    now="$(date '+%Y-%m-%d %H:%M')"
    current="$(ytdlp_version "$([ -d "${YTDLP}" ] && echo "${YTDLP}")")"
    rm -rf "${YTDLP}.new"
    index=''

    # (another package index, for the tests: trusted even over plain HTTP)
    if [ -n "${YTDLP_INDEX_URL}" ]; then
        index="--index-url=${YTDLP_INDEX_URL}"
        index="${index} --trusted-host=$(echo "${YTDLP_INDEX_URL}" | sed 's#^[a-z]*://##; s#[:/].*##')"
    fi

    # (yt-dlp's JavaScript challenge solver comes with it: they're released together)
    if ! "${PYTHON}" -m pip install --disable-pip-version-check --no-cache-dir --quiet ${index} --no-deps \
        --target "${YTDLP}.new" --upgrade yt-dlp yt-dlp-ejs >> "${METUBE_LOG}" 2>&1; then
        printf '%s failed: could not download yt-dlp (still %s)\n' "${now}" "${current}" > "${YTDLP_STATUS}"
        rm -rf "${YTDLP}.new"
        log "yt-dlp: could not download it, keeping ${current}"

        return 1
    fi

    new="$(ytdlp_version "${YTDLP}.new")"

    if [ -z "${new}" ] || ! PYTHONPATH="${YTDLP}.new" "${PYTHON}" -m yt_dlp --version > /dev/null 2>&1; then
        printf '%s failed: the new yt-dlp did not run (still %s)\n' "${now}" "${current}" > "${YTDLP_STATUS}"
        rm -rf "${YTDLP}.new"
        log "yt-dlp: the new one did not run, keeping ${current}"

        return 1
    fi

    if [ "${new}" = "${current}" ] && [ -d "${YTDLP}" ]; then
        rm -rf "${YTDLP}.new"
        printf '%s ok: %s (up to date)\n' "${now}" "${current}" > "${YTDLP_STATUS}"

        return 0
    fi

    chown -R "$1:$2" "${YTDLP}.new"
    rm -rf "${YTDLP}.old"
    [ -d "${YTDLP}" ] && mv "${YTDLP}" "${YTDLP}.old"
    mv "${YTDLP}.new" "${YTDLP}"
    rm -rf "${YTDLP}.old"
    printf '%s ok: %s (was %s)\n' "${now}" "${new}" "${current}" > "${YTDLP_STATUS}"
    log "yt-dlp updated: ${current} -> ${new}"

    if running "${PID_FILE}"; then
        stop_one "${PID_FILE}" MeTube
        start_metube
    fi
}

# The Nginx app finds the Watch page by its folder (its nginx.json): rewrite its sites
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

# Keeps its logs under 1MB each.
#
# Returns 0
rotate_logs() {
    local file

    for file in "${METUBE_LOG}" "${WATCH_LOG}"; do
        if [ "$(wc -c < "${file}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            cp "${file}" "${file}.1" && : > "${file}"
            chmod 600 "${file}.1"
        fi
    done

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
    ytdlp) update_ytdlp "$2" ;;
    nginx) nginx_site ;;
    daily) rotate_logs ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|ytdlp [force]|nginx|daily" >&2

        exit 1
        ;;
esac
