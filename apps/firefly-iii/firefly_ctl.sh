#!/bin/sh
# Runs Firefly III (a personal finance manager: accounts, budgets, bills, categories, rules and reports) as its own
# user, with the PHP app's PHP 8.5: PHP's own web server, with a few workers, on port 8088. Its accounts and
# transactions are kept in the NAS's MariaDB (WD's own, or the MariaDB app's - a database and login of its own, made by
# the app: firefly); its attachments, keys and other data in the persistent path (Nas_Prog/_firefly-iii - kept across
# reinstalls). The Nginx app serves it at https://firefly.<its domain> - by default (LISTEN=local, when the Nginx app is
# installed) only that way: it then listens on the NAS itself only (127.0.0.1). With LISTEN=all it's also at
# http://<nas-ip>:8088 on the local network. Its owner (admin@nas.local, with a password the app generates) is made
# on its first start:
#   firefly_ctl.sh setup        - create its user, folders and settings (where missing)
#   firefly_ctl.sh start        - write its settings, update its database after a new version (its login and database
#                                 made first, once MariaDB answers), then start it (checking it answers)
#   firefly_ctl.sh stop         - stop it
#   firefly_ctl.sh restart      - stop, then start
#   firefly_ctl.sh set-password - a new password for its owner, read from the input (one line)
#   firefly_ctl.sh backup       - back up its database and files (while it runs)
#   firefly_ctl.sh cron         - Firefly III's own daily jobs (recurring transactions, automatic budgets, bill
#                                 reminders)
#   firefly_ctl.sh daily        - the daily job: Firefly III's own jobs, a backup, and keeping the logs small
#   firefly_ctl.sh nginx        - rewrite the Nginx app's sites (Firefly III's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_firefly-iii"
BIN="${APP_PATH}/binaries"
FF="${BIN}/firefly"
# Firefly III's own data (attachments, its API's keys, sessions, caches, its log): its user's
STORAGE="${DATA_PATH}/storage"
# Its settings (.env, with its database password and key): written at every start, root's, readable by its group - plus
# any settings of your own (extra.env, e.g. for sending email), added to them
CONF_PATH="${DATA_PATH}/conf"
ENV_FILE="${CONF_PATH}/.env"
EXTRA_ENV="${CONF_PATH}/extra.env"
SETTINGS_FILE="${DATA_PATH}/settings"
# Its owner's password, and its ID in Firefly III (to give it a new password, whatever its email address becomes)
PASSWORD_FILE="${DATA_PATH}/password"
ADMIN_ID_FILE="${DATA_PATH}/admin_id"
# Its encryption key (made once: Firefly III can't read what it encrypted without it), the version its database was last
# brought up to date for, its database login's password, and how setting the database up last went
APP_KEY_FILE="${DATA_PATH}/app_key"
DB_VERSION_FILE="${DATA_PATH}/db_version"
DB_PASSWORD_FILE="${DATA_PATH}/db_password"
DB_STATUS="${DATA_PATH}/db.status"
# PHP's web server's log (each request, and PHP's errors)
SERVER_LOG="${DATA_PATH}/server.log"
PID_FILE=/var/run/firefly-iii.pid
PORT=8088
ADMIN_EMAIL=admin@nas.local
# Its database and login in MariaDB
DB=firefly
# Its own user and group (created if missing): the IDs used when creating them
FF_ID=55
LOG=/tmp/debug_apkg

# The PHP app's PHP 8.5 (Firefly III needs 8.5 or later: the NAS's own is 7.4)
PHP="${APPS_PATH}/php/binaries/php"
# Laravel's router for PHP's own web server (in Firefly III's folder)
ROUTER=vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php
# The NAS's MariaDB (WD's own, or the MariaDB app's - the same socket): root logs in over it without a password
SOCKET=/var/lib/mysql/mysql.sock

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') firefly-iii/firefly_ctl.sh $*" >> ${LOG}
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

# Whether Firefly III is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
ff_ids() {
    awk -F: '$1 == "firefly" { print $3 " " $4 }' /etc/passwd
}

# The version of Firefly III in the package.
#
# Prints it (e.g. 6.7.9)
ff_version() {
    sed -n "s/^ *'version' *=> *'\([^']*\)'.*/\1/p" "${FF}/config/firefly.php" 2>/dev/null | head -n 1
}

# One of MariaDB's programs: the MariaDB app's, else the NAS's own.
#
# $1 mariadb_name Its name in the MariaDB app (e.g. mariadb-dump)
# $2 wd_name      The NAS's own (e.g. mysqldump)
#
# Prints its path
mariadb_program() {
    program="${APPS_PATH}/mariadb/binaries/mariadb/bin/$1"
    [ -x "${program}" ] \
        || program="$(PATH="/usr/bin:/bin:/usr/local/bin:/usr/local/modules/mysql/bin:${PATH}" command -v "$2")"
    echo "${program:-$2}"
}

# Runs MariaDB's client as root (over the socket).
#
# $@ The client's arguments (the SQL on the input, or -e)
#
# Prints its output
mysql_root() {
    "$(mariadb_program mariadb mysql)" --socket="${SOCKET}" -uroot "$@"
}

# Whether MariaDB answers root.
#
# Returns 0 if it does
db_answering() {
    mysql_root -N -e 'SELECT 1' > /dev/null 2>&1
}

# Notes how setting up the database went, for the page.
#
# $1 state   ok or failed
# $2 message Why it failed (none if ok)
db_status() {
    printf '%s %s %s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" > "${DB_STATUS}"
}

# Makes Firefly III's login and database in MariaDB (or gives the login a new password): all rights on its own database,
# none on anything else. MariaDB is started the NAS's way first if it isn't running (WD's MariaDB only runs when an app
# asks for it), then waited for.
#
# $1 wait Seconds to wait for MariaDB (default 0)
#
# Prints what happened; returns 0 once it's done
db_login() {
    if ! db_answering && ! pidof mariadbd mysqld > /dev/null 2>&1 && [ -f /usr/bin/mysql_reset.py ]; then
        log "starting the NAS's MariaDB"
        python3 /usr/bin/mysql_reset.py -d > /dev/null 2>&1
    fi

    waited=0

    until db_answering; do
        if [ ${waited} -ge "${1:-0}" ]; then
            db_status failed "MariaDB is not answering as root on its socket (${SOCKET}) - is it running?"
            log 'MariaDB is not answering as root on its socket - is it running?'

            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done

    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

    if ! output="$(mysql_root 2>&1 <<EOF
CREATE DATABASE IF NOT EXISTS ${DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB}'@'localhost';
ALTER USER '${DB}'@'localhost' IDENTIFIED BY '${password}';
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DB}'@'localhost';
FLUSH PRIVILEGES;
EOF
)"; then
        db_status failed "$(echo "${output}" | tr '\n' ' ' | cut -c1-300)"
        log "Could not set up its database in MariaDB: ${output}"

        return 1
    fi

    ( umask 077; printf '%s' "${password}" > "${DB_PASSWORD_FILE}.tmp" ) \
        && mv -f "${DB_PASSWORD_FILE}.tmp" "${DB_PASSWORD_FILE}" || return 1
    # (Its database may be new: brought up to date at the next start, whatever version it was last for)
    rm -f "${DB_VERSION_FILE}"
    db_status ok ''
    log 'its database and login in MariaDB are set up'
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^firefly:' /etc/group || addgroup -g ${FF_ID} firefly
    grep -q '^firefly:' /etc/passwd || adduser -D -H -h "${STORAGE}" -s /bin/false -u ${FF_ID} -G firefly firefly

    if [ -z "$(ff_ids)" ]; then
        log "Could not create the firefly user (are ID ${FF_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(ff_ids)

    # Its folder: root's (settings, passwords, key, backups), passable for Firefly III; its settings readable by its
    # group; its own data its user's - begun from the package's (its folders), then Firefly III's own
    mkdir -p "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"

    if [ ! -d "${STORAGE}" ] && [ -d "${FF}/storage.dist" ]; then
        cp -a "${FF}/storage.dist" "${STORAGE}"
    fi

    mkdir -p "${STORAGE}/app/public" "${STORAGE}/build" "${STORAGE}/database" "${STORAGE}/export" "${STORAGE}/logs" \
        "${STORAGE}/upload" "${STORAGE}/framework/cache/data" "${STORAGE}/framework/sessions" \
        "${STORAGE}/framework/views"
    chown -R "$1:$2" "${STORAGE}"
    chmod 700 "${STORAGE}"

    # Firefly III finds its settings and data in its own folder: links to them (the package's folder is replaced by an
    # update, so they're made again at every boot)
    if [ -d "${FF}" ]; then
        ln -sfn "${ENV_FILE}" "${FF}/.env"
        rm -rf "${FF}/storage"
        ln -sfn "${STORAGE}" "${FF}/storage"
    fi

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_DIR=\nBACKUP_KEEP=7\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # Its encryption key, made once (32 characters, as Firefly III asks for)
    if [ ! -s "${APP_KEY_FILE}" ]; then
        ( umask 077; printf '%s\n' "$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)" > "${APP_KEY_FILE}" )
    fi

    touch "${SERVER_LOG}"
    chmod 600 "${SERVER_LOG}"
}

# Firefly III's address: the Nginx app's site for it, else the NAS's own address on its port (used in its emails and
# its API's sign-in links).
#
# Prints the address, without a trailing /
app_url() {
    url="$("${PHP}" -n -r 'require $argv[1];
        $site = manage_nginx_site($argv[2], "http://127.0.0.1:".$argv[3]);
        echo rtrim($site["url"], "/");' "${APP_PATH}/manage/manage_helpers.php" "${APPS_PATH}" "${PORT}" 2>/dev/null)"

    if [ -z "${url}" ]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
        url="http://${ip:-127.0.0.1}:${PORT}"
    fi

    echo "${url}"
}

# Writes Firefly III's settings (.env): its key and address, its database (over MariaDB's socket, its own login), the
# NAS's time zone, its owner's email address, its log (errors and warnings only), and no email unless set up in
# extra.env.
#
# $1 url Its address
#
# Returns 0 once they're written
write_env() {
    set -- $(ff_ids) "$1"
    # The NAS's time zone (WD's php.ini has it)
    timezone="$(sed -n 's/^date\.timezone *= *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' /etc/php/php.ini 2>/dev/null \
        | head -n 1)"
    # Secure cookies only when it's reachable over HTTPS alone (the Nginx app's site, LISTEN=local)
    secure=false

    case "$3" in
        https:*) [ "$(setting LISTEN local)" = local ] && secure=true ;;
    esac

    ( umask 027; {
        cat <<EOF
# Written by the Firefly III app at every start (firefly_ctl.sh) - changes here are lost: add your own settings to
# extra.env (next to this file), e.g. MAIL_MAILER=smtp and MAIL_HOST=... to send email
APP_KEY=$(cat "${APP_KEY_FILE}")
APP_URL=$3
APP_ENV=production
APP_DEBUG=false
SITE_OWNER=${ADMIN_EMAIL}
TZ=${timezone:-UTC}
TRUSTED_PROXIES=127.0.0.1
DB_CONNECTION=mysql
DB_HOST=localhost
DB_SOCKET=${SOCKET}
DB_DATABASE=${DB}
DB_USERNAME=${DB}
DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
CACHE_STORE=file
SESSION_DRIVER=file
COOKIE_SECURE=${secure}
QUEUE_CONNECTION=sync
LOG_CHANNEL=single
APP_LOG_LEVEL=notice
AUDIT_LOG_LEVEL=emergency
MAIL_MAILER=log
EOF

        if [ -f "${EXTRA_ENV}" ]; then
            printf '\n# Your own settings (extra.env)\n'
            cat "${EXTRA_ENV}"
        fi
    } > "${ENV_FILE}.tmp" ) && chown "root:$2" "${ENV_FILE}.tmp" && chmod 640 "${ENV_FILE}.tmp" \
        && mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
}

# Runs one of Firefly III's own commands (artisan), or the app's owner helper, as its own user from its folder.
#
# $@ php's arguments (e.g. artisan firefly-iii:cron)
#
# Prints its output
ff_php() {
    set -- $(ff_ids) "$@"
    uid="$1"
    gid="$2"
    shift 2
    ( cd "${FF}" && HOME="${STORAGE}" exec "${BIN}/firefly_runas" "${uid}" "${gid}" "${PHP}" -n -d memory_limit=512M \
        "$@" )
}

# Brings its database up to date when the package's Firefly III is a new version (or its database is new): its own
# upgrade (its tables, then its data's corrections), its API's keys (made once), and its compiled pages cleared.
#
# Returns 0 once it's up to date
db_upgrade() {
    version="$(ff_version)"

    [ "$(cat "${DB_VERSION_FILE}" 2>/dev/null)" = "${version}" ] && [ -s "${STORAGE}/oauth-private.key" ] && return 0

    log "bringing its database up to date for Firefly III ${version}"

    if ! output="$(ff_php artisan firefly-iii:upgrade-database --no-interaction 2>&1)"; then
        log "Could not update Firefly III's database: $(echo "${output}" | tail -n 5)"

        return 1
    fi

    ff_php artisan firefly-iii:laravel-passport-keys --no-interaction > /dev/null 2>&1
    ff_php artisan view:clear --no-interaction > /dev/null 2>&1
    ff_php artisan cache:clear --no-interaction > /dev/null 2>&1
    printf '%s\n' "${version}" > "${DB_VERSION_FILE}"
}

# Gives its owner a password (from the input), through Firefly III itself (lib/admin.php): in use at once.
#
# Returns 0 once it's set
admin_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    id="$(cat "${ADMIN_ID_FILE}" 2>/dev/null)"

    if [ -z "${id}" ]; then
        log 'Its owner has not been set up yet (start Firefly III first)'

        return 1
    fi

    if ! output="$(printf '%s\n' "${password}" | ff_php "${APP_PATH}/lib/admin.php" set "${id}" 2>&1)"; then
        log "Could not set its owner's password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

# Whether it's Firefly III answering (its login page), while its web server is still running - not something else on
# the port.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 90 ]; do
        running || return 1
        curl -sf -m 5 "http://127.0.0.1:${PORT}/login" 2>/dev/null | grep -q 'FF3-broken-base-href' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running; then
        log "Firefly III is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    if [ ! -x "${PHP}" ]; then
        log 'Firefly III needs the PHP app (PHP 8.5): install it first'

        return 1
    fi

    setup || return 1

    # Its database and login: made the first time - at boot, MariaDB may start after this app, so it's waited for in
    # the background, then Firefly III started
    if [ ! -s "${DB_PASSWORD_FILE}" ] && ! db_login 15; then
        log 'waiting for MariaDB in the background, to set up its database'
        ( sh "${APP_PATH}/firefly_ctl.sh" later > /dev/null 2>&1 & )

        return 0
    fi

    url="$(app_url)"
    write_env "${url}" || { log "Could not write its settings: ${ENV_FILE}"; return 1; }
    db_upgrade || return 1

    # Its first start: its owner (the first user, who manages the others) made with the app's email address and a
    # generated password - before its web server starts, so nobody else can sign up first
    if [ ! -s "${PASSWORD_FILE}" ] || [ ! -s "${ADMIN_ID_FILE}" ]; then
        password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"

        if ! id="$(printf '%s\n' "${password}" | ff_php "${APP_PATH}/lib/admin.php" first "${ADMIN_EMAIL}" 2>&1)"; then
            log "Could not set up its owner: ${id}"

            return 1
        fi

        ( umask 077; printf '%s\n' "${id}" > "${ADMIN_ID_FILE}"; printf '%s\n' "${password}" > "${PASSWORD_FILE}" )
        log "its owner is ${ADMIN_EMAIL} (its password is shown on the app's page)"
    fi

    set -- $(ff_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting Firefly III on ${host}:${PORT} (${url})"
    # Laravel's router serves from its public folder (where it's run)
    cd "${FF}/public" || return 1
    # PHP's own web server with 4 workers (each request to one of them), Laravel's router; opcache on (each worker keeps
    # Firefly III's code compiled); attachments up to 64MB (the Nginx app passes any size)
    ( HOME="${STORAGE}" PHP_CLI_SERVER_WORKERS=4 exec "${BIN}/firefly_runas" "$1" "$2" "${PHP}" -n \
        -d memory_limit=512M -d upload_max_filesize=64M -d post_max_size=64M -d max_execution_time=300 \
        -d display_errors=0 -d log_errors=1 -d opcache.enable_cli=1 -d opcache.memory_consumption=96 \
        -d opcache.validate_timestamps=0 -d date.timezone=UTC \
        -S "${host}:${PORT}" -t "${FF}/public" "${FF}/${ROUTER}" ) \
        >> "${SERVER_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "Firefly III did not start (see ${SERVER_LOG}): $(tail -n 2 "${SERVER_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "Firefly III started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Firefly III (PID ${pid})"

        # Its workers first: they're its children - found by their parent, as BusyBox's pkill may lack -P
        for proc in /proc/[0-9]*; do
            [ "$(awk '{ print $4 }' "${proc}/stat" 2>/dev/null)" = "${pid}" ] && kill "${proc#/proc/}" 2>/dev/null
        done

        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 10 ]; then
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Firefly III's own daily jobs: its recurring transactions made, its automatic budgets set, its bill reminders - only
# while it runs (its database is then set up).
#
# Returns 0 once they've run
ff_cron() {
    running || return 0

    if ! output="$(ff_php artisan firefly-iii:cron --no-interaction 2>&1)"; then
        log "Firefly III's daily jobs failed: $(echo "${output}" | tail -n 3)"

        return 1
    fi
}

# Backs up Firefly III: its database (mariadb-dump / mysqldump, as its own login - a consistent copy while it runs), its
# attachments, its API's keys and its key (without which what it encrypted can't be read) - one archive, root's only, in
# the backup folder, keeping the newest ones. Restored as the app's README says.
#
# Returns 0 once it's written
backup() {
    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -s "${DB_PASSWORD_FILE}" ]; then
        log 'Nothing to back up yet (its database has not been set up)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    stamp="$(date '+%Y%m%d-%H%M%S')"
    work="${dir}/.firefly-iii-${stamp}"
    file="${dir}/firefly-iii-${stamp}.tar.gz"
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    if ! output="$(MYSQL_PWD="$(cat "${DB_PASSWORD_FILE}")" "$(mariadb_program mariadb-dump mysqldump)" \
        --socket="${SOCKET}" -u"${DB}" --single-transaction --routines --no-tablespaces "${DB}" \
        2>&1 > "${work}/firefly.sql")" \
        || ! tail -n 1 "${work}/firefly.sql" | grep -q 'Dump completed'; then
        log "The database backup failed: ${output}"
        rm -rf "${work}"

        return 1
    fi

    cp "${APP_KEY_FILE}" "${work}/app_key"
    [ -f "${EXTRA_ENV}" ] && cp "${EXTRA_ENV}" "${work}/extra.env"

    # (Its API's keys only once made, at its first start)
    keys=''

    for key in oauth-private.key oauth-public.key; do
        [ -f "${STORAGE}/${key}" ] && keys="${keys} ${key}"
    done

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . -C "${STORAGE}" upload ${keys} ) \
        || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -rf "${work}" "${file}.tmp"

        return 1
    fi

    rm -rf "${work}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/firefly-iii-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' \
        | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps PHP's web server's log and Firefly III's own under 1MB each (the previous part is kept as .1)
rotate_logs() {
    for file in "${SERVER_LOG}" "${STORAGE}/logs/laravel.log"; do
        if [ "$(wc -c < "${file}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            cp -p "${file}" "${file}.1" && : > "${file}"
        fi
    done
}

# The Nginx app finds Firefly III by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
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
    later)
        # (Started by start: waits up to 5 minutes for MariaDB, then starts Firefly III)
        db_login 300 && start
        ;;
    set-password) admin_password ;;
    backup) backup ;;
    cron) ff_cron ;;
    daily)
        ff_cron
        backup
        rotate_logs
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|backup|cron|daily|nginx" >&2

        exit 1
        ;;
esac
