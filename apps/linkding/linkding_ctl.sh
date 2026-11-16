#!/bin/sh
# Runs linkding (a bookmark manager) as its own user: its web server (uWSGI, on port 9099) and its background worker
# (favicons, previews, Wayback Machine snapshots), with its data in the persistent path Nas_Prog/_linkding - kept across
# reinstalls. The Nginx app serves it at https://linkding.<its domain> - by default (LISTEN=local, when the Nginx app is
# installed) only that way: it then listens on the NAS itself only (127.0.0.1). With LISTEN=all it's also at
# http://<nas-ip>:9099 on the local network. Its admin user (admin, with a password the app generates) is made on its
# first start - linkding has no sign-ups, so nobody else can claim it:
#   linkding_ctl.sh setup        - create its user, folders and settings (where missing)
#   linkding_ctl.sh start        - update its database, then start it (checking it answers)
#   linkding_ctl.sh stop         - stop it
#   linkding_ctl.sh restart      - stop, then start
#   linkding_ctl.sh set-password - a new password for its admin user, read from the input (one line)
#   linkding_ctl.sh backup       - back up its bookmarks, files and settings (its own full backup)
#   linkding_ctl.sh daily        - the daily job: a backup, and keeping its log small
#   linkding_ctl.sh nginx        - rewrite the Nginx app's sites (linkding's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_linkding"
BIN="${APP_PATH}/binaries"
PYTHON="${BIN}/python/bin/python3"
# linkding itself (it runs from its own folder: its data/ is a link to LD_DATA)
LD_APP="${BIN}/linkding"
# linkding's own data (its databases, favicons, previews, uploaded files, secret key): its user's
LD_DATA="${DATA_PATH}/data"
# Its user's temporary files (e.g. a backup being written), on the data's disk (the NAS's /tmp is in memory)
LD_TMP="${DATA_PATH}/tmp"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
LD_LOG="${DATA_PATH}/linkding.log"
PID_FILE=/var/run/linkding.pid
TASKS_PID_FILE=/var/run/linkding-tasks.pid
PORT=9099
# Its admin user's name
ADMIN=admin
# Its own user and group (created if missing): the IDs used when creating them
LD_ID=56
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') linkding/linkding_ctl.sh $*" >> ${LOG}
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

# Whether a process (its PID file's) is running.
#
# $1 pid_file The PID file
#
# Returns 0 if it is
running() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
ld_ids() {
    awk -F: '$1 == "linkding" { print $3 " " $4 }' /etc/passwd
}

# Runs a program as linkding's own user, in its folder, with its settings in the environment - in place of the
# current shell, so it's only called in a subshell. The addresses it accepts forms from: its Nginx site's, and the
# NAS's own on its port.
#
# $@ The program and its arguments
#
# Doesn't return
run_as_ld() {
    local ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
    local php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
    local origins="$("${php:-php}" "${APP_PATH}/lib/linkding.php" origins "${APPS_PATH}" "${ip:-127.0.0.1}" \
        "$(hostname)" 2>/dev/null)"

    set -- $(ld_ids) "$@"
    cd "${LD_APP}" || exit 1
    exec env HOME="${LD_DATA}" TMPDIR="${LD_TMP}" DJANGO_SETTINGS_MODULE=bookmarks.settings.prod \
        LD_LIBRARY_PATH="${BIN}/python/lib" LD_CSRF_TRUSTED_ORIGINS="${origins}" LD_LOG_X_FORWARDED_FOR=true \
        "${BIN}/linkding_runas" "$@"
}

# Runs one of linkding's management commands (Django's manage.py), as its own user.
#
# $@ The command and its arguments (e.g. migrate --noinput)
#
# Prints its output
manage() {
    ( run_as_ld "${PYTHON}" manage.py "$@" )
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings, and the
# link from linkding's data/ to its data folder.
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^linkding:' /etc/group || addgroup -g ${LD_ID} linkding
    grep -q '^linkding:' /etc/passwd || adduser -D -H -h "${LD_DATA}" -s /bin/false -u ${LD_ID} -G linkding linkding

    if [ -z "$(ld_ids)" ]; then
        log "Could not create the linkding user (are ID ${LD_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(ld_ids)

    # Its folder: root's (settings, password, backups), passable for linkding; its data and temporary files its own
    mkdir -p "${LD_DATA}" "${LD_TMP}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${LD_DATA}" "${LD_TMP}"
    chmod 700 "${LD_DATA}" "${LD_TMP}"
    ln -sfn "${LD_DATA}" "${LD_APP}/data"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${LD_LOG}"
    chmod 600 "${LD_LOG}"
}

# Sets the admin user's password (Django hashes it), from the input - creating the user if it's missing.
#
# Returns 0 once it's set
admin_password() {
    local password="$(head -n 1 | tr -d '\r\n')"
    local output

    case "${password}" in
        '' | *[!A-Za-z0-9._~-]*)
            log 'Passwords are letters, digits and . _ ~ - only'

            return 1
            ;;
    esac

    # Given in the command's environment, not on its command line (which other programs on the NAS can read) - exported
    # in a subshell: BusyBox's sh doesn't pass a VAR=value given before a function on to the programs it runs
    if ! output="$(export LINKDING_NEW_PASSWORD="${password}"; manage shell -c "
import os
from django.contrib.auth import get_user_model
User = get_user_model()
user = User.objects.filter(username='${ADMIN}').first() or User(username='${ADMIN}')
user.is_staff = user.is_superuser = user.is_active = True
user.set_password(os.environ['LINKDING_NEW_PASSWORD'])
user.save()" 2>&1)"; then
        log "Could not set the admin user's password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

# Whether it's linkding answering (its login page), while its web server is still running - not something else on
# the port.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt 60 ]; do
        running "${PID_FILE}" || return 1
        curl -s -m 3 "http://127.0.0.1:${PORT}/login/" 2>/dev/null | grep -qi 'linkding' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

# Starts it: its secret key (made once), its database created or brought up to date (after an update), its admin user
# the first time, then its web server and background worker.
#
# Prints what it did; returns 0 once it answers
start() {
    local output
    local host=127.0.0.1

    if running "${PID_FILE}" && running "${TASKS_PID_FILE}"; then
        log "linkding is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    stop
    setup || return 1

    if ! output="$(manage generate_secret_key 2>&1 && manage migrate --noinput 2>&1 && manage enable_wal 2>&1 \
        && manage migrate_tasks 2>&1)"; then
        log "Could not update linkding's database: $(echo "${output}" | tail -n 5)"

        return 1
    fi

    if [ ! -s "${PASSWORD_FILE}" ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | admin_password || return 1
        log "created its admin user: ${ADMIN} (its password is shown on the app's page)"
    fi

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting linkding on ${host}:${PORT} (log: ${LD_LOG})"
    # (with its master process: stopping it stops its workers too, so the port is free again)
    ( run_as_ld "${BIN}/python/bin/uwsgi" --master --http "${host}:${PORT}" uwsgi.ini ) >> "${LD_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    ( run_as_ld "${PYTHON}" manage.py run_huey -f ) >> "${LD_LOG}" 2>&1 &
    echo $! > "${TASKS_PID_FILE}"

    if ! wait_up; then
        log "linkding did not start (see ${LD_LOG}): $(tail -n 2 "${LD_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "linkding started with PID: $(cat ${PID_FILE}) (its worker: $(cat ${TASKS_PID_FILE}))"
}

# Stops a process (its PID file's), letting it finish its work first (up to 30 seconds).
#
# $1 pid_file The PID file
#
# Prints nothing; returns 0 once stopped
stop_process() {
    local pid
    local waited=0

    if running "$1"; then
        pid="$(cat "$1")"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "$1"
}

# Stops its web server and background worker.
#
# Prints what it did; returns 0 once stopped
stop() {
    if running "${PID_FILE}" || running "${TASKS_PID_FILE}"; then
        log 'stopping linkding (its web server and worker)'
    fi

    stop_process "${PID_FILE}"
    stop_process "${TASKS_PID_FILE}"
}

# Backs up its bookmarks, uploaded files, favicons and previews with linkding's own full backup (a .zip, with a safe
# copy of its database while it runs), in Nas_Prog/_linkding/backups - root's only - keeping the newest ones.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local name="linkding-$(date '+%Y%m%d-%H%M%S').zip"
    local output item

    if [ ! -f "${LD_DATA}/db.sqlite3" ]; then
        log 'Nothing to back up yet (no database - linkding has not started yet)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1

    # (written by linkding as its own user, in its own temporary folder, then moved to root's backups)
    if ! output="$(manage full_backup "${LD_TMP}/${name}" 2>&1)" || ! mv -f "${LD_TMP}/${name}" "${dir}/${name}"; then
        rm -f "${LD_TMP}/${name}"
        log "The backup failed: $(echo "${output}" | tail -n 3)"

        return 1
    fi

    chown root:root "${dir}/${name}"
    chmod 600 "${dir}/${name}"
    log "backed up to: ${dir}/${name}"

    # Keep only the newest backups
    ls -1 "${dir}"/linkding-*.zip 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r item; do
        rm -f "${item}"
    done
}

# Keeps its log under 1MB (the previous part is kept as linkding.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${LD_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${LD_LOG}" "${LD_LOG}.1" && : > "${LD_LOG}"
        chmod 600 "${LD_LOG}.1"
    fi

    return 0
}

# The Nginx app finds linkding by its folder (its nginx.json): rewrite its sites, and reload it.
#
# Prints nothing; returns 0 (with or without the Nginx app)
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"
    # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
    local php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
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
    set-password) setup && admin_password ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
