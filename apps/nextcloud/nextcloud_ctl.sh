#!/bin/sh
# Runs Nextcloud (files, calendars and contacts, synced with computers and phones) as its own user: its own web server
# (the Nginx app's program) and PHP (the PHP app's php-fpm), on port 8097 - by default (LISTEN=local) on the NAS itself
# only, reached through the Nginx app at https://nextcloud.<its domain>; with LISTEN=all also at http://<nas-ip>:8097 on
# the local network. Its database is in the PostgreSQL app's server (a database and login of its own, made by the app:
# nextcloud); its files, settings and logs in the persistent path (Nas_Prog/_nextcloud - kept across reinstalls). It's
# installed on its first start, with an administrator (admin, with a password the app generates). Run by the app's
# scripts, its management page and cron:
#   nextcloud_ctl.sh setup        - create its user, folders and settings (where missing)
#   nextcloud_ctl.sh start        - start it (its database and login made first, once PostgreSQL answers - in the
#                                   background at boot; installed, or upgraded to the app's version, first if need be)
#   nextcloud_ctl.sh stop         - stop it
#   nextcloud_ctl.sh restart      - stop, then start
#   nextcloud_ctl.sh cron         - its background jobs (every 5 minutes, from root's crontab)
#   nextcloud_ctl.sh set-password - a new password for its administrator, read from the input (one line)
#   nextcloud_ctl.sh scan         - find files added to its data folder some other way (occ files:scan)
#   nextcloud_ctl.sh occ ...      - its console (occ), as its user - e.g. nextcloud_ctl.sh occ status
#   nextcloud_ctl.sh backup       - back up its database (pg_dump, while it runs)
#   nextcloud_ctl.sh daily        - the daily job: a backup, and keeping the logs small
#   nextcloud_ctl.sh nginx        - rewrite the Nginx app's sites (Nextcloud's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_nextcloud"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
NEXTCLOUD="${BIN}/nextcloud"
RUN="${DATA_PATH}/run"
SETTINGS_FILE="${DATA_PATH}/settings"
# Its administrator's password, its database login's password (both root's), and how setting the database up last went
PASSWORD_FILE="${DATA_PATH}/password"
DB_PASSWORD_FILE="${DATA_PATH}/db_password"
DB_STATUS="${DATA_PATH}/db.status"
# (root's: noted when they're started - Nginx keeps its own in its run folder too)
NGINX_PID=/var/run/nextcloud-nginx.pid
FPM_PID=/var/run/nextcloud-php-fpm.pid
PORT=8097
DB=nextcloud
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
# (so that shares can be added to it as external storage)
NEXTCLOUD_ID=64
LOG=/tmp/debug_apkg

# The other apps' programs: PHP (its CLI, and php-fpm - run under a name of its own: WD's php-fpm.sh finds its own
# php-fpm by its file name, and would stop this one with it), Nginx (likewise under its own name), PostgreSQL's client
PHP="${APPS_PATH}/php/binaries/php"
PHP_FPM_SOURCE="${APPS_PATH}/php/binaries/php-fpm"
PHP_FPM="${BIN}/nextcloud-php-fpm"
NGINX_SOURCE="${APPS_PATH}/nginx/binaries/nginx"
NGINX="${BIN}/nextcloud-nginx"
PG_BIN="${APPS_PATH}/postgresql/binaries/postgresql/bin"
PG_SUPERUSER_PASSWORD="${APPS_PATH}/_postgresql/postgres_password"
PG_SOCKET=/var/run/postgresql

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') nextcloud/nextcloud_ctl.sh $*" >> ${LOG}
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

# Whether a PID file's process is running.
#
# $1 file The PID file
#
# Returns 0 if it is
running() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# The nextcloud user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
nc_ids() {
    awk -F: '$1 == "nextcloud" { print $3 " " $4 }' /etc/passwd
}

# Runs Nextcloud's console (occ) as its user, with its PHP settings and its configuration's folder.
#
# $@ occ's arguments
#
# Prints its output; returns its exit code
occ() {
    local ids

    ids="$(nc_ids)"
    ( cd "${NEXTCLOUD}" && exec env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="${RUN}" \
        NEXTCLOUD_CONFIG_DIR="${DATA_PATH}/config" PHP_INI_SCAN_DIR= ${OC_PASS:+OC_PASS="${OC_PASS}"} \
        "${BIN}/nextcloud_runas" ${ids} "${PHP}" -c "${RUN}/php.ini" occ "$@" < /dev/null )
}

# Runs psql as PostgreSQL's postgres superuser (over its socket), with its password in the environment.
#
# $@ psql's arguments (the SQL on the input, or -c)
#
# Prints psql's output
psql_superuser() {
    PGPASSWORD="$(cat "${PG_SUPERUSER_PASSWORD}" 2>/dev/null)" "${PG_BIN}/psql" -h "${PG_SOCKET}" -U postgres \
        -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
}

# Whether PostgreSQL answers the superuser.
#
# Returns 0 if it does
db_answering() {
    [ -x "${PG_BIN}/psql" ] && psql_superuser -c 'SELECT 1' > /dev/null 2>&1
}

# Notes how setting up the database went, for the page.
#
# $1 state   ok or failed
# $2 message Why it failed (none if ok)
db_status() {
    printf '%s %s %s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" > "${DB_STATUS}"
}

# Makes Nextcloud's login and database in PostgreSQL (the login owns the database, and can do nothing else). Waits for
# PostgreSQL to answer first.
#
# $1 wait Seconds to wait for PostgreSQL (default 0)
#
# Prints what happened; returns 0 once it's done
db_login() {
    local waited=0 password output

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            db_status failed 'PostgreSQL is not answering - is the PostgreSQL app installed and running?'
            log 'PostgreSQL is not answering - is the PostgreSQL app installed and running?'

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

    # A database can't be created in a transaction (DO blocks are one), so whether it exists is asked first
    if ! output="$(psql_superuser 2>&1 <<EOF
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB}') THEN
        CREATE ROLE ${DB};
    END IF;
END \$\$;
ALTER ROLE ${DB} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${password}';
EOF
)"; then
        db_status failed "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)"
        log "Could not set up its login in PostgreSQL: ${output}"

        return 1
    fi

    if [ "$(psql_superuser -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB}'" 2>/dev/null)" != 1 ]; then
        if ! output="$(psql_superuser -c "CREATE DATABASE ${DB} OWNER ${DB} ENCODING 'UTF8'" 2>&1)"; then
            db_status failed "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)"
            log "Could not create its database: ${output}"

            return 1
        fi

        log "created its database in PostgreSQL: ${DB}"
    fi

    ( umask 077; printf '%s' "${password}" > "${DB_PASSWORD_FILE}.tmp" ) \
        && mv -f "${DB_PASSWORD_FILE}.tmp" "${DB_PASSWORD_FILE}" || return 1

    # Nextcloud keeps its database password in its own configuration: the new one there too (once it's installed)
    if grep -q "'installed' => true" "${DATA_PATH}/config/config.php" 2>/dev/null; then
        occ config:system:set dbpassword --value="${password}" > /dev/null || return 1
    fi

    db_status ok ''
    log 'its database login is set up'
}

setup() {
    local group dir listen file

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^nextcloud:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=nextcloud
            grep -q '^nextcloud:' /etc/group || addgroup -g ${NEXTCLOUD_ID} nextcloud
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${NEXTCLOUD_ID} -G ${group} nextcloud
    fi

    if [ -z "$(nc_ids)" ]; then
        log "Could not create the nextcloud user (is ID ${NEXTCLOUD_ID} already taken?)"

        return 1
    fi

    set -- $(nc_ids)

    # Its folder: root's (settings, passwords, backups), passable for Nextcloud; its configuration, files, apps from the
    # app store, logs and run files its user's (Nextcloud wants its data folder for itself: 770)
    mkdir -p "${DATA_PATH}/config" "${DATA_PATH}/data" "${DATA_PATH}/custom_apps" "${DATA_PATH}/logs"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"

    for dir in config data custom_apps logs; do
        chown "$1:$2" "${DATA_PATH}/${dir}"
    done

    chmod 750 "${DATA_PATH}/config" "${DATA_PATH}/custom_apps" "${DATA_PATH}/logs"
    chmod 770 "${DATA_PATH}/data"

    # Its logs: its user's (its programs open them as it)
    for file in nextcloud.log nginx-error.log php-fpm.log php-errors.log cron.log upgrade.log; do
        touch "${DATA_PATH}/logs/${file}"
        chown "$1:$2" "${DATA_PATH}/logs/${file}"
        chmod 640 "${DATA_PATH}/logs/${file}"
    done

    # Its run files: made afresh at every start
    rm -rf "${RUN}"
    mkdir -p "${RUN}/sessions" "${RUN}/uploads" "${RUN}/tmp"
    chown -R "$1:$2" "${RUN}"
    chmod 700 "${RUN}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_DIR=\nBACKUP_KEEP=7\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
}

# The NAS's address on the local network.
#
# Prints it (nothing if there's none)
address() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1
}

# Writes its web server's and PHP's settings from the app's templates (conf/) into its run folder, and its settings for
# Nextcloud (config/nas.config.php): its address, the Nginx app's site, its folders.
#
# Returns 0 once they're written
write_config() {
    local listen="127.0.0.1:${PORT}" timezone file

    [ "$(setting LISTEN local)" = all ] && listen="${PORT}"
    timezone="$(cat /etc/TZ 2>/dev/null | head -n 1)"
    [ -f /etc/timezone ] && timezone="$(head -n 1 /etc/timezone)"

    # (a timezone PHP knows by name, else UTC)
    case "${timezone}" in
        */*) ;;
        *) timezone=UTC ;;
    esac

    # (the Nginx app's MIME types and FastCGI parameters: copied, as its folder is root's)
    cp "${APPS_PATH}/_nginx/params/mime.types" "${APPS_PATH}/_nginx/params/fastcgi_params" "${RUN}/" || return 1

    for file in nginx.conf php-fpm.conf php.ini; do
        sed "s|__DATA__|${DATA_PATH}|g; s|__NEXTCLOUD__|${NEXTCLOUD}|g; s|__LISTEN__|${listen}|g; \
            s|__NGINX_PARAMS__|${RUN}|g; s|__TIMEZONE__|${timezone}|g" \
            "${APP_PATH}/conf/${file}" > "${RUN}/${file}" || return 1
    done

    chmod 644 "${RUN}"/*.conf "${RUN}/php.ini" "${RUN}/mime.types" "${RUN}/fastcgi_params"

    php "${APP_PATH}/lib/nextcloud.php" config "${DATA_PATH}" "${APP_PATH}" "$(setting LISTEN local)" "$(address)"
}

# Installs Nextcloud (its first start): its tables in its database, its administrator - admin, with a generated
# password (given on its command line only as a throwaway one, replaced at once by the app's own through occ's
# environment) - its background jobs from cron.
#
# Returns 0 once it's installed
install() {
    local first output

    log 'installing Nextcloud (a few minutes)'
    first="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"

    if ! output="$(occ maintenance:install --no-interaction --database pgsql --database-host 127.0.0.1 \
        --database-name "${DB}" --database-user "${DB}" --database-pass "$(cat "${DB_PASSWORD_FILE}")" \
        --admin-user admin --admin-pass "${first}" --data-dir "${DATA_PATH}/data" 2>&1)"; then
        log "Nextcloud could not be installed: $(echo "${output}" | tail -n 5 | tr '\n' ' ')"

        return 1
    fi

    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | admin_password || return 1
    occ background:cron > /dev/null
    log 'Nextcloud installed: its administrator is admin (its password is shown on the app page)'
}

# Gives its administrator (admin) a password (from the input), through occ's environment: in use at once.
#
# Returns 0 once it's set
admin_password() {
    local password output

    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    if ! output="$(OC_PASS="${password}" occ user:resetpassword --password-from-env admin 2>&1)"; then
        log "Could not set its administrator's password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

# Whether Nextcloud answers (its status page), while its web server and PHP still run.
#
# $1 wait Seconds to wait
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    while [ ${waited} -lt "$1" ]; do
        running "${NGINX_PID}" && running "${FPM_PID}" || return 1
        curl -sf -m 5 "http://127.0.0.1:${PORT}/status.php" 2>/dev/null | grep -q '"installed":true' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running "${NGINX_PID}" && running "${FPM_PID}"; then
        log "Nextcloud is already running (its web server's PID: $(cat ${NGINX_PID}))"

        return 0
    fi

    stop > /dev/null
    setup || return 1

    if [ ! -x "${PHP}" ] || [ ! -x "${PHP_FPM_SOURCE}" ] || [ ! -x "${NGINX_SOURCE}" ] || [ ! -d "${APPS_PATH}/_nginx/params" ]; then
        log 'Nextcloud needs the PHP and Nginx apps: install them first'

        return 1
    fi

    # Its database and login: made the first time - at boot, PostgreSQL may start after this app, so it's waited for in
    # the background, then Nextcloud started
    if [ ! -s "${DB_PASSWORD_FILE}" ] && ! db_login 10; then
        log 'waiting for PostgreSQL in the background, to set up its database'
        ( sh "${APP_PATH}/nextcloud_ctl.sh" later > /dev/null 2>&1 & )

        return 0
    fi

    # The other apps' programs under names of their own (hard links: they don't take any room)
    rm -f "${PHP_FPM}" "${NGINX}"
    ln "${PHP_FPM_SOURCE}" "${PHP_FPM}" 2>/dev/null || cp "${PHP_FPM_SOURCE}" "${PHP_FPM}"
    ln "${NGINX_SOURCE}" "${NGINX}" 2>/dev/null || cp "${NGINX_SOURCE}" "${NGINX}"
    write_config || { log 'Could not write its settings'; return 1; }

    # Installed the first time; upgraded when the app brings a new version (its database follows its code)
    if ! grep -q "'installed' => true" "${DATA_PATH}/config/config.php" 2>/dev/null; then
        install || return 1
    elif occ status --output=json 2>/dev/null | grep -q '"needsDbUpgrade":true'; then
        log "upgrading Nextcloud's database to $(sed -n "s/^\$OC_VersionString = '\(.*\)';/\1/p" "${NEXTCLOUD}/version.php")"
        occ upgrade --no-interaction >> "${DATA_PATH}/logs/upgrade.log" 2>&1 || { log "The upgrade failed (see ${DATA_PATH}/logs/upgrade.log)"; return 1; }
        occ db:add-missing-indices --no-interaction >> "${DATA_PATH}/logs/upgrade.log" 2>&1
        occ maintenance:mode --off > /dev/null 2>&1
    fi

    set -- $(nc_ids)
    log "starting Nextcloud on port ${PORT}"
    # (both in the foreground, as the app's background processes - their PIDs noted at once: they'd write them only once
    # they're set up)
    ( exec env -i PATH=/usr/local/bin:/usr/bin:/bin PHP_INI_SCAN_DIR= "${BIN}/nextcloud_runas" "$1" "$2" "${PHP_FPM}" \
        -c "${RUN}/php.ini" -y "${RUN}/php-fpm.conf" ) >> "${DATA_PATH}/logs/php-fpm.log" 2>&1 &
    echo $! > "${FPM_PID}"
    ( exec "${BIN}/nextcloud_runas" "$1" "$2" "${NGINX}" -p "${RUN}/" -c "${RUN}/nginx.conf" \
        -e "${DATA_PATH}/logs/nginx-error.log" -g 'daemon off;' ) >> "${DATA_PATH}/logs/nginx-error.log" 2>&1 &
    echo $! > "${NGINX_PID}"

    if ! wait_up 120; then
        log "Nextcloud did not start (see ${DATA_PATH}/logs): $(tail -n 3 "${DATA_PATH}/logs/nginx-error.log" \
            "${DATA_PATH}/logs/php-fpm.log" 2>/dev/null | tr '\n' ' ' | cut -c1-400)"

        return 1
    fi

    log "Nextcloud started (its web server's PID: $(cat ${NGINX_PID}))"
}

# Stops a process from its PID file (waiting up to 30 seconds, then killing it).
#
# $1 file The PID file
# $2 name What it is, for the log
#
# Prints nothing
stop_one() {
    local pid waited=0

    if running "$1"; then
        pid="$(cat "$1")"
        log "stopping $2 (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${waited}" -ge 30 ]; then
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
    stop_one "${NGINX_PID}" "Nextcloud's web server"
    stop_one "${FPM_PID}" "Nextcloud's PHP"
}

# Runs its background jobs (cron.php, as its user) - once it's installed and running, one run at a time.
#
# Prints nothing
cron() {
    running "${FPM_PID}" && grep -q "'installed' => true" "${DATA_PATH}/config/config.php" 2>/dev/null || return 0
    mkdir /var/run/nextcloud-cron 2>/dev/null || return 0
    set -- $(nc_ids)
    ( cd "${NEXTCLOUD}" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="${RUN}" NEXTCLOUD_CONFIG_DIR="${DATA_PATH}/config" \
        PHP_INI_SCAN_DIR= "${BIN}/nextcloud_runas" "$1" "$2" "${PHP}" -c "${RUN}/php.ini" -f cron.php ) \
        >> "${DATA_PATH}/logs/cron.log" 2>&1
    rmdir /var/run/nextcloud-cron
}

# Backs up its database (its users, shares, calendars, contacts and the files' records - not the files themselves) with
# PostgreSQL's pg_dump, as its own login - a consistent copy while it runs - into the backup folder, keeping the newest
# ones. Restored with pg_restore (see the app's README).
#
# Returns 0 once it's written
backup() {
    local dir keep file output old

    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -s "${DB_PASSWORD_FILE}" ]; then
        log 'Nothing to back up yet (its database has not been set up)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    file="${dir}/nextcloud-$(date '+%Y%m%d-%H%M%S').dump"

    if ! output="$( ( umask 077; PGPASSWORD="$(cat "${DB_PASSWORD_FILE}")" "${PG_BIN}/pg_dump" -h "${PG_SOCKET}" \
        -U "${DB}" -d "${DB}" -Fc -f "${file}.tmp" ) 2>&1)" || ! mv -f "${file}.tmp" "${file}"; then
        log "The backup failed: ${output}"
        rm -f "${file}.tmp"

        return 1
    fi

    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/nextcloud-*.dump 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps its web server's, PHP's and cron's logs under 1MB each (the previous part is kept as <log>.1). Nextcloud keeps
# its own log (nextcloud.log) small itself.
#
# Prints nothing
rotate_logs() {
    local file

    for file in nginx-error.log php-fpm.log php-errors.log cron.log upgrade.log; do
        file="${DATA_PATH}/logs/${file}"

        if [ "$(wc -c < "${file}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            cp "${file}" "${file}.1" && : > "${file}"
        fi
    done
}

# The Nginx app finds Nextcloud by its folder (its nginx.json): rewrite its sites.
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
    later)
        # (Started by start: waits up to 5 minutes for PostgreSQL, then starts Nextcloud)
        db_login 300 && start
        ;;
    cron) cron ;;
    set-password) admin_password ;;
    scan) occ files:scan --all ;;
    occ)
        shift
        occ "$@"
        ;;
    backup) backup ;;
    daily)
        backup
        rotate_logs
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|cron|set-password|scan|occ ...|backup|daily|nginx" >&2

        exit 1
        ;;
esac
