#!/bin/sh
# Runs Paperless-ngx (document management with OCR) as its own user, in the NAS's share group, with its data in the
# persistent path Nas_Prog/_paperless-ngx - kept across reinstalls. Run by the app's scripts and its management page:
#   pl_ctl.sh setup            - create its user, folders, settings, secret key and admin password (where missing)
#   pl_ctl.sh start            - start it in the background: once the Valkey app answers, update its database, then
#                                start its web server (port 8040), consumer, task worker and scheduler
#   pl_ctl.sh stop             - stop all of them
#   pl_ctl.sh restart          - stop, then start
#   pl_ctl.sh new-password     - give the admin user a new generated password (at once, nothing restarted)
#   pl_ctl.sh manage <command> - run one of Paperless's management commands (e.g. document_exporter <folder>)
#   pl_ctl.sh daily            - the daily job: keeping its log small
#   pl_ctl.sh nginx            - add / update Paperless's site in the Nginx app (and reload it)
#
# Documents dropped in its consume folder (a share: Public/Paperless by default) are imported, OCRed and removed from
# there; Paperless keeps them (originals and searchable PDF archives) in its own data folder

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
VOLUME_PATH="$(dirname "${APPS_PATH}")"
DATA_PATH="${APPS_PATH}/_paperless-ngx"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
SRC="${BIN}/paperless/src"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
SECRET_FILE="${DATA_PATH}/secret_key"
STATE_FILE="${DATA_PATH}/state"
PL_LOG="${DATA_PATH}/paperless.log"
RUN_PATH=/var/run/paperless-ngx
SERVICES='web consumer worker scheduler'
PORT=8040
# The Valkey app (its configuration has its port and password)
VALKEY_CONF="${APPS_PATH}/_valkey/valkey.conf"
VALKEY_CLI="${APPS_PATH}/valkey/binaries/valkey-cli"
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
PL_ID=96
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') paperless-ngx/pl_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. CONSUME_DIR)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether one of Paperless's processes is running (its PID file's process, if it's still Paperless's).
#
# $1 service web, consumer, worker, scheduler or launcher
#
# Returns 0 if it is
service_running() {
    local pid

    pid="$(cat "${RUN_PATH}/$1.pid" 2>/dev/null)"
    # Its own (a PID left behind may have gone to another process since): started by this app's script or Python
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && grep -qa "${APP_PATH}/" "/proc/${pid}/cmdline" 2>/dev/null
}

# Whether Paperless is running: any of its processes, or its launcher (waiting for Valkey, or updating its database).
#
# Returns 0 if it is
running() {
    local service

    for service in launcher ${SERVICES}; do
        service_running "${service}" && return 0
    done

    return 1
}

# The paperless user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
pl_ids() {
    awk -F: '$1 == "paperless" { print $3 " " $4 }' /etc/passwd
}

# A value from Valkey's configuration.
#
# $1 key The setting (e.g. port, requirepass)
#
# Prints its value
valkey_conf() {
    awk -v key="$1" '$1 == key { print $2; exit }' "${VALKEY_CONF}" 2>/dev/null
}

# Whether the Valkey app answers.
#
# Returns 0 if it does
valkey_up() {
    [ "$(REDISCLI_AUTH="$(valkey_conf requirepass)" VALKEYCLI_AUTH="$(valkey_conf requirepass)" "${VALKEY_CLI}" \
        -h 127.0.0.1 -p "$(valkey_conf port)" ping 2>/dev/null)" = PONG ]
}

# Writes a secret (letters and digits) to a file only root can read.
#
# $1 file   The file to write
# $2 length The number of characters
#
# Prints nothing
new_secret() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$2" > "$1.tmp" ) && mv -f "$1.tmp" "$1"
}

setup() {
    local group consume_dir

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one: it removes what it imports from the consume folder, a share
    if ! grep -q '^paperless:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=paperless
            grep -q '^paperless:' /etc/group || addgroup -g ${PL_ID} paperless
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${PL_ID} -G ${group} paperless
    fi

    if [ -z "$(pl_ids)" ]; then
        log "Could not create the paperless user (is ID ${PL_ID} already taken?)"

        return 1
    fi

    set -- $(pl_ids)

    # Python's multiprocessing (Celery's worker pool) keeps its semaphores in /dev/shm, which WD's firmware lacks (or has
    # as a plain folder only root can write in): a small shared memory file system there, as any other Linux system has
    if ! awk '$2 == "/dev/shm" { found = 1 } END { exit !found }' /proc/self/mounts; then
        mkdir -p /dev/shm && mount -t tmpfs -o mode=1777,size=64m,nosuid,nodev shm /dev/shm \
            && log 'mounted a shared memory file system on /dev/shm (Celery needs one)'
    fi

    chmod 1777 /dev/shm 2>/dev/null

    # Its data (database, search index, documents, its own log and temporary files) belongs to its user; the page's
    # settings and the secrets to root
    mkdir -p "${DATA_PATH}/data" "${DATA_PATH}/media" "${DATA_PATH}/tmp" "${DATA_PATH}/home" "${RUN_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${DATA_PATH}/data" "${DATA_PATH}/media" "${DATA_PATH}/tmp" "${DATA_PATH}/home"
    chmod 700 "${DATA_PATH}/data" "${DATA_PATH}/media" "${DATA_PATH}/tmp" "${DATA_PATH}/home"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'CONSUME_DIR=%s\nOCR_LANGUAGE=eng\nLISTEN=all\n' "${VOLUME_PATH}/Public/Paperless" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${SECRET_FILE}" ] || new_secret "${SECRET_FILE}" 64
    [ -s "${PASSWORD_FILE}" ] || { new_secret "${PASSWORD_FILE}" 20; log 'generated the admin password'; }
    touch "${PL_LOG}"
    chmod 600 "${PL_LOG}"

    # The consume folder (made the first time, in the share group, writable by it - so that anyone can drop files in)
    consume_dir="$(setting CONSUME_DIR "${VOLUME_PATH}/Public/Paperless")"

    if [ ! -d "${consume_dir}" ]; then
        log "creating the consume folder: ${consume_dir}"
        mkdir -p "${consume_dir}" && chown "$1:$2" "${consume_dir}" && chmod 2775 "${consume_dir}"
    fi

    # Paperless removes what it imports, so its group must be able to write in the folder chosen (an existing one may not
    # let it): the folder's group becomes the share group, with write access - nothing else changes
    if ! ( cd / && "${BIN}/pl_runas" "$1" "$2" /bin/sh -c '[ -w "$0" ]' "${consume_dir}" ) 2>/dev/null; then
        log "letting the share group write in the consume folder: ${consume_dir}"
        chgrp "$2" "${consume_dir}" && chmod g+rwxs "${consume_dir}"
    fi
}

# Its address on the Nginx app (HTTPS), if it has a site there.
#
# Prints it (ending in /), or nothing
site_url() {
    php "${APP_PATH}/lib/paperless.php" url "${APPS_PATH}" 2>/dev/null
}

# Runs a command as Paperless's user, with its settings (in its environment - with Valkey's password and the secret key,
# which other users can't read there), from its source folder. PAPERLESS_ADMIN_PASSWORD and PL_NEW_PASSWORD are passed
# on when set (for the admin user).
#
# $@ The command and its arguments
#
# Prints what it prints
as_paperless() {
    local host=0.0.0.0 ip site origins ids

    ids="$(pl_ids)"
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    site="$(site_url)"
    # Where its pages may be opened from (for Django's CSRF checks): the Nginx app's site, and its own port by the NAS's
    # address and name
    origins="http://${ip:-127.0.0.1}:${PORT},http://$(hostname):${PORT},http://localhost:${PORT}${site:+,${site%/}}"
    cd "${SRC}" || return 1
    env -i PATH="${BIN}/bin:${BIN}/python/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG=C.UTF-8 HOME="${DATA_PATH}/home" \
        TMPDIR="${DATA_PATH}/tmp" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
        PYTHONWARNINGS='ignore:::django.http.response:517' \
        SSL_CERT_FILE="${BIN}/python/lib/python3.14/site-packages/certifi/cacert.pem" \
        TESSDATA_PREFIX="${BIN}/tessdata" MAGIC="${BIN}/magic.mgc" \
        GS_LIB="${BIN}/ghostscript/Resource/Init:${BIN}/ghostscript/lib:${BIN}/ghostscript/Resource/Font" \
        GS_OPTIONS="-sICCProfilesDir=${BIN}/icc/ghostscript/" FONTCONFIG_FILE="${BIN}/fonts/fonts.conf" \
        PAPERLESS_DATA_DIR="${DATA_PATH}/data" PAPERLESS_MEDIA_ROOT="${DATA_PATH}/media" \
        PAPERLESS_SCRATCH_DIR="${DATA_PATH}/tmp" PAPERLESS_STATICDIR="${BIN}/paperless/static" \
        PAPERLESS_CONSUMPTION_DIR="$(setting CONSUME_DIR "${VOLUME_PATH}/Public/Paperless")" \
        PAPERLESS_REDIS="redis://:$(valkey_conf requirepass)@127.0.0.1:$(valkey_conf port)" \
        PAPERLESS_REDIS_PREFIX=paperless \
        PAPERLESS_SECRET_KEY="$(cat "${SECRET_FILE}")" \
        PAPERLESS_ALLOWED_HOSTS='*' PAPERLESS_CSRF_TRUSTED_ORIGINS="${origins}" \
        ${site:+PAPERLESS_URL="${site%/}"} PAPERLESS_PROXY_SSL_HEADER='["HTTP_X_FORWARDED_PROTO", "https"]' \
        PAPERLESS_BIND_ADDR="${host}" PAPERLESS_PORT="${PORT}" \
        PAPERLESS_OCR_LANGUAGE="$(setting OCR_LANGUAGE eng)" \
        PAPERLESS_TASK_WORKERS=1 PAPERLESS_THREADS_PER_WORKER=2 PAPERLESS_WEBSERVER_WORKERS=1 \
        PAPERLESS_THUMBNAIL_FONT_NAME="${BIN}/fonts/LiberationSerif-Regular.ttf" \
        PAPERLESS_ENABLE_UPDATE_CHECK=false \
        ${PAPERLESS_ADMIN_PASSWORD:+PAPERLESS_ADMIN_PASSWORD="${PAPERLESS_ADMIN_PASSWORD}"} \
        ${PL_NEW_PASSWORD:+PL_NEW_PASSWORD="${PL_NEW_PASSWORD}"} \
        "${BIN}/pl_runas" ${ids} "$@"
}

# Starts one of Paperless's processes in the background, recording its PID.
#
# $1 service The name it's known by (web, consumer, worker or scheduler)
# $@         Then the command and its arguments (run as Paperless's user)
#
# Prints nothing
start_service() {
    local service="$1"

    shift
    ( as_paperless "$@" ) >> "${PL_LOG}" 2>&1 &
    echo $! > "${RUN_PATH}/${service}.pid"
}

# Waits for Valkey (as at boot, when it may start after Paperless), updates the database (its migrations, the first
# admin user), then starts Paperless's four processes. Run in the background by start.
#
# Prints what it does (to Paperless's log)
launch() {
    local waited=0

    echo 'waiting for Valkey' > "${STATE_FILE}"

    until valkey_up; do
        if [ "${waited}" -ge 600 ]; then
            log 'The Valkey app did not answer within 10 minutes: Paperless was not started'
            echo 'no Valkey' > "${STATE_FILE}"
            rm -f "${RUN_PATH}/launcher.pid"

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    echo 'updating its database' > "${STATE_FILE}"
    log 'updating its database (migrations)'

    if ! as_paperless "${PYTHON}" manage.py migrate --no-input >> "${PL_LOG}" 2>&1; then
        log "Its database could not be updated, see: ${PL_LOG}"
        echo 'database failed' > "${STATE_FILE}"
        rm -f "${RUN_PATH}/launcher.pid"

        return 1
    fi

    # The admin user, the first time only (afterwards its password is changed in Paperless, or from the page)
    PAPERLESS_ADMIN_PASSWORD="$(cat "${PASSWORD_FILE}")" as_paperless "${PYTHON}" manage.py manage_superuser \
        >> "${PL_LOG}" 2>&1

    start_service web "${PYTHON}" -m granian --interface asginl --ws --loop uvloop --host "$(listen_host)" \
        --port ${PORT} --workers 1 paperless.asgi:application
    start_service consumer "${PYTHON}" manage.py document_consumer --skip-checks
    start_service worker "${PYTHON}" -m celery --skip-checks --app paperless worker --loglevel INFO --without-mingle \
        --without-gossip
    start_service scheduler "${PYTHON}" -m celery --skip-checks --app paperless beat --loglevel INFO
    echo 'running' > "${STATE_FILE}"
    rm -f "${RUN_PATH}/launcher.pid"
    log "Paperless started: web $(cat "${RUN_PATH}/web.pid"), consumer $(cat "${RUN_PATH}/consumer.pid"), worker $(cat "${RUN_PATH}/worker.pid"), scheduler $(cat "${RUN_PATH}/scheduler.pid")"
}

# The address its web server listens on: the network, or the NAS itself only.
#
# Prints it
listen_host() {
    if [ "$(setting LISTEN all)" = local ]; then
        echo 127.0.0.1
    else
        echo 0.0.0.0
    fi
}

start() {
    if running; then
        log 'Paperless is already running'

        return 0
    fi

    setup || return 1

    if [ ! -f "${VALKEY_CONF}" ] || [ ! -x "${VALKEY_CLI}" ]; then
        log 'Paperless needs the Valkey app: install it first'
        echo 'no Valkey' > "${STATE_FILE}"

        return 1
    fi

    log "starting Paperless in the background (log: ${PL_LOG})"
    ( launch ) >> "${PL_LOG}" 2>&1 &
    echo $! > "${RUN_PATH}/launcher.pid"
}

# The processes descended from one (its children, theirs...).
#
# $1 pid The process
#
# Prints their PIDs, one a line
descendants() {
    local child

    for child in $(awk -v parent="$1" '$4 == parent { print $1 }' /proc/[0-9]*/stat 2>/dev/null); do
        echo "${child}"
        descendants "${child}"
    done
}

# Paperless's processes: everything its own user runs (by user ID - not by command line: Granian's and Celery's workers
# rename themselves).
#
# Prints their PIDs, one a line
paperless_processes() {
    local uid

    uid="$(awk -F: '$1 == "paperless" { print $3 }' /etc/passwd)"
    [ -n "${uid}" ] || return 0
    awk -v uid="${uid}" '/^Uid:/ && $2 == uid { split(FILENAME, path, "/"); print path[3] }' /proc/[0-9]*/status 2>/dev/null
}

stop() {
    local service pid pids waited=0

    for service in launcher ${SERVICES}; do
        if service_running "${service}"; then
            pid="$(cat "${RUN_PATH}/${service}.pid")"
            # Its process and everything it started (Celery's worker processes, Granian's workers)
            pids="$(descendants "${pid}" | tr '\n' ' ')"
            log "stopping Paperless's ${service} (PID ${pid}${pids:+, and ${pids% }})"
            kill ${pids} "${pid}" 2>/dev/null
        fi
    done

    # They finish what they're doing first (e.g. a document being OCRed)
    while running || [ -n "$(paperless_processes)" ]; do
        if [ "${waited}" -ge 60 ]; then
            log 'Paperless did not stop within 60 seconds, killing it'
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    # Anything still left of it (e.g. a worker process whose parent was killed)
    for pid in $(paperless_processes); do
        log "killing what's left of Paperless: PID ${pid}"
        kill -9 "${pid}" 2>/dev/null
    done

    rm -f "${RUN_PATH}"/*.pid
    echo 'stopped' > "${STATE_FILE}"
}

# Gives the admin user a new generated password, at once (in Paperless's database - it doesn't need a restart).
#
# Prints what it did
new_password() {
    new_secret "${PASSWORD_FILE}.new" 20

    if PL_NEW_PASSWORD="$(cat "${PASSWORD_FILE}.new")" as_paperless "${PYTHON}" manage.py shell -c '
import os
from django.contrib.auth.models import User
user, _ = User.objects.get_or_create(username="admin")
user.is_superuser = user.is_staff = user.is_active = True
user.set_password(os.environ["PL_NEW_PASSWORD"])
user.save()
' >> "${PL_LOG}" 2>&1; then
        mv -f "${PASSWORD_FILE}.new" "${PASSWORD_FILE}"
        log 'gave the admin user a new password'
    else
        rm -f "${PASSWORD_FILE}.new"
        log 'Could not set a new admin password (has Paperless started once?)'

        return 1
    fi
}

# Keeps the app's log under 2MB (the previous part is kept as paperless.log.1). Paperless rotates its own logs, in its
# data folder.
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${PL_LOG}" 2>/dev/null || echo 0)" -gt 2097152 ]; then
        cp "${PL_LOG}" "${PL_LOG}.1" && : > "${PL_LOG}"
        chmod 600 "${PL_LOG}.1"
    fi
}

# The Nginx app finds Paperless by its folder and serves it at https://paperless.<its domain>: rewrite its sites.
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
    manage)
        shift
        as_paperless "${PYTHON}" manage.py "$@"
        ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|manage <command>|daily|nginx" >&2

        exit 1
        ;;
esac
