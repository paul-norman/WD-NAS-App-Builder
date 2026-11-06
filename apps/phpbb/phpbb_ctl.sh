#!/bin/sh
# Runs phpBB (a discussion forum) as its own user, with the PHP app's PHP 8.5: PHP's own web server, with a few workers,
# on port 8089. Its posts, users and settings are kept in the NAS's MariaDB (WD's own, or the MariaDB app's - a
# database and login of its own, made by the app: phpbb); its attachments, avatars, extensions and other data in the
# persistent path (Nas_Prog/_phpbb - kept across reinstalls). The Nginx app serves it at https://phpbb.<its domain> -
# by default (LISTEN=local, when the Nginx app is installed) only that way: it then listens on the NAS itself only
# (127.0.0.1). With LISTEN=all it's also at http://<nas-ip>:8089 on the local network. The board is installed on its
# first start, with an administrator (admin, with a password the app generates):
#   phpbb_ctl.sh setup        - create its user, folders and settings (where missing)
#   phpbb_ctl.sh start        - install the board the first time (else bring its database up to date), set its
#                               address, then start it (checking it answers)
#   phpbb_ctl.sh stop         - stop it
#   phpbb_ctl.sh restart      - stop, then start
#   phpbb_ctl.sh set-password - a new password for its administrator, read from the input (one line)
#   phpbb_ctl.sh backup       - back up its database and files (while it runs)
#   phpbb_ctl.sh daily        - the daily job: a backup, and keeping the log small
#   phpbb_ctl.sh nginx        - rewrite the Nginx app's sites (phpBB's comes from its nginx.json), and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_phpbb"
BIN="${APP_PATH}/binaries"
BB="${BIN}/phpbb"
# phpBB's installer: kept beside the board (phpBB refuses to show it while an install folder is there), moved into
# place only while the board is installed
INSTALLER="${BB}/install.dist"
# phpBB's own data, its user's: its cache, its backups and logs (store), attachments (files) and uploaded avatars
CACHE="${DATA_PATH}/cache"
STORE="${DATA_PATH}/store"
FILES="${DATA_PATH}/files"
AVATARS="${DATA_PATH}/avatars"
# Extensions added to it (root's: phpBB only reads them)
EXT="${DATA_PATH}/ext"
# Its settings (config.php, with its database password): written at every start, root's, readable by its group
CONF_PATH="${DATA_PATH}/conf"
CONFIG_FILE="${CONF_PATH}/config.php"
SETTINGS_FILE="${DATA_PATH}/settings"
# Its administrator's password, and its user ID in phpBB (to give it a new password, whatever its name becomes)
PASSWORD_FILE="${DATA_PATH}/password"
ADMIN_ID_FILE="${DATA_PATH}/admin_id"
# Its database login's password, and how setting the database up last went (for the page)
DB_PASSWORD_FILE="${DATA_PATH}/db_password"
DB_STATUS="${DATA_PATH}/db.status"
# PHP's web server's log (each request, and PHP's errors)
SERVER_LOG="${DATA_PATH}/server.log"
PID_FILE=/var/run/phpbb.pid
PORT=8089
ADMIN=admin
ADMIN_EMAIL=admin@nas.local
# Its database and login in MariaDB, and its tables' prefix
DB=phpbb
PREFIX=phpbb_
# Its own user and group (created if missing): the IDs used when creating them
BB_ID=69
LOG=/tmp/debug_apkg

# The PHP app's PHP 8.5 (the NAS's own is 7.4)
PHP="${APPS_PATH}/php/binaries/php"
# The NAS's MariaDB (WD's own, or the MariaDB app's - the same socket): root logs in over it without a password
SOCKET=/var/lib/mysql/mysql.sock

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') phpbb/phpbb_ctl.sh $*" >> ${LOG}
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

# Whether phpBB is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
bb_ids() {
    awk -F: '$1 == "phpbb" { print $3 " " $4 }' /etc/passwd
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

# Runs MariaDB's client as phpBB's own login, in its database (its password in the environment).
#
# $@ The client's arguments (the SQL on the input, or -e)
#
# Prints its output
mysql_bb() {
    MYSQL_PWD="$(cat "${DB_PASSWORD_FILE}" 2>/dev/null)" "$(mariadb_program mariadb mysql)" --socket="${SOCKET}" \
        -u"${DB}" -N "${DB}" "$@"
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

# Makes phpBB's login and database in MariaDB (or gives the login a new password): all rights on its own database, none
# on anything else. MariaDB is started the NAS's way first if it isn't running (WD's MariaDB only runs when an app asks
# for it), then waited for.
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
    db_status ok ''
    log 'its database and login in MariaDB are set up'
}

# Makes one of phpBB's data folders (from the package's, the first time) and links it into phpBB's folder in place of
# the package's (made again at every boot: an update replaces the package's folder).
#
# $1 folder Its folder in the data path
# $2 place  Where phpBB has it (relative to phpBB's folder, e.g. images/avatars/upload)
# $3 owner  Its owner (user:group)
# $4 mode   Its mode (e.g. 700)
data_folder() {
    if [ ! -d "$1" ]; then
        if [ -d "${BB}/$2" ] && [ ! -L "${BB}/$2" ]; then
            cp -a "${BB}/$2" "$1"
        else
            mkdir -p "$1"
        fi
    fi

    chown -R "$3" "$1"
    chmod "$4" "$1"

    if [ -d "${BB}" ]; then
        rm -rf "${BB:?}/$2"
        ln -sfn "$1" "${BB}/$2"
    fi
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^phpbb:' /etc/group || addgroup -g ${BB_ID} phpbb
    grep -q '^phpbb:' /etc/passwd || adduser -D -H -h "${CACHE}" -s /bin/false -u ${BB_ID} -G phpbb phpbb

    if [ -z "$(bb_ids)" ]; then
        log "Could not create the phpbb user (are ID ${BB_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(bb_ids)

    # Its folder: root's (settings, passwords, backups), passable for phpBB; its settings readable by its group; its
    # own data its user's; extensions root's (phpBB only reads them)
    mkdir -p "${CONF_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"
    chown "root:$2" "${CONF_PATH}"
    chmod 750 "${CONF_PATH}"
    data_folder "${CACHE}" cache "$1:$2" 700
    data_folder "${STORE}" store "$1:$2" 700
    data_folder "${FILES}" files "$1:$2" 700
    data_folder "${AVATARS}" images/avatars/upload "$1:$2" 700
    data_folder "${EXT}" ext root:root 755
    [ -f "${CONFIG_FILE}" ] || : > "${CONFIG_FILE}"
    [ -d "${BB}" ] && ln -sfn "${CONFIG_FILE}" "${BB}/config.php"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Only through the Nginx app - HTTPS - when it's installed
        listen=all
        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_DIR=\nBACKUP_KEEP=7\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${SERVER_LOG}"
    chmod 600 "${SERVER_LOG}"
}

# phpBB's address: the Nginx app's site for it, else the NAS's own address on its port. phpBB makes its links (and the
# ones in its emails) from it.
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

# Writes phpBB's settings (config.php), once the board is installed: its database (over MariaDB's socket - phpBB takes
# a socket as the port) and its own login.
#
# Returns 0 once they're written
write_config() {
    set -- $(bb_ids)

    ( umask 027; cat > "${CONFIG_FILE}.tmp" <<EOF
<?php
// Written by the phpBB app at every start (phpbb_ctl.sh) - changes here are lost
\$dbms = 'phpbb\\\\db\\\\driver\\\\mysqli';
\$dbhost = 'localhost';
\$dbport = '${SOCKET}';
\$dbname = '${DB}';
\$dbuser = '${DB}';
\$dbpasswd = '$(cat "${DB_PASSWORD_FILE}")';
\$table_prefix = '${PREFIX}';
\$phpbb_adm_relative_path = 'adm/';
\$acm_type = 'phpbb\\\\cache\\\\driver\\\\file';

@define('PHPBB_INSTALLED', true);
@define('PHPBB_ENVIRONMENT', 'production');
// @define('DEBUG_CONTAINER', true);
EOF
    ) && chown "root:$2" "${CONFIG_FILE}.tmp" && chmod 640 "${CONFIG_FILE}.tmp" \
        && mv -f "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
}

# Runs PHP (one of phpBB's own command-line tools, or the app's helpers) as phpBB's user, from phpBB's folder.
#
# $@ php's arguments (e.g. bin/phpbbcli.php db:migrate)
#
# Prints its output
bb_php() {
    set -- $(bb_ids) "$@"
    uid="$1"
    gid="$2"
    shift 2
    ( cd "${BB}" && HOME="${CACHE}" exec "${BIN}/phpbb_runas" "${uid}" "${gid}" "${PHP}" -n -d memory_limit=512M \
        -d mysqli.default_socket="${SOCKET}" "$@" )
}

# Whether the board is installed: its settings table in its database.
#
# Returns 0 if it is
installed() {
    [ -n "$(mysql_bb -e "SELECT config_value FROM ${PREFIX}config WHERE config_name = 'version'" 2>/dev/null)" ]
}

# Installs the board with phpBB's own installer (its command-line one, given a configuration file): its tables, the
# administrator with a generated password, English, no email until it's set up in phpBB, its address. The installer
# is moved into place for it, and back again.
#
# $1 url Its address
#
# Returns 0 once it's installed
install_board() {
    set -- $(bb_ids) "$1"
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    protocol="${3%%://*}://"
    rest="${3#*://}"
    host="${rest%%:*}"
    port="${rest#*:}"
    [ "${port}" = "${rest}" ] && port=443 && [ "${protocol}" = 'http://' ] && port=80
    secure=false
    [ "${protocol}" = 'https://' ] && secure=true
    yml="${CONF_PATH}/install.yml"

    ( umask 027; cat > "${yml}" <<EOF
installer:
    admin:
        name: ${ADMIN}
        password: ${password}
        email: ${ADMIN_EMAIL}
    board:
        lang: en
        name: Forum
        description: A discussion forum on the NAS
    database:
        dbms: mysqli
        dbhost: localhost
        dbport: ${SOCKET}
        dbuser: ${DB}
        dbpasswd: $(cat "${DB_PASSWORD_FILE}")
        dbname: ${DB}
        table_prefix: ${PREFIX}
    email:
        enabled: false
        smtp_delivery: ~
        smtp_host: ~
        smtp_port: ~
        smtp_auth: ~
        smtp_user: ~
        smtp_pass: ~
    server:
        cookie_secure: ${secure}
        server_protocol: ${protocol}
        force_server_vars: true
        server_name: ${host}
        server_port: ${port}
        script_path: /
    extensions: []
EOF
    ) && chown "root:$2" "${yml}" && chmod 640 "${yml}" || return 1

    # The installer writes config.php itself (the app then writes its own over it)
    chown "$1:$2" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    mv "${INSTALLER}" "${BB}/install" || return 1
    log "installing the board (${3})"
    output="$(bb_php install/phpbbcli.php install "${yml}" 2>&1)"
    status=$?
    mv "${BB}/install" "${INSTALLER}"
    rm -f "${yml}"

    if [ ${status} -ne 0 ] || ! installed; then
        log "Could not install the board: $(echo "${output}" | tail -n 8)"

        return 1
    fi

    # The installer opens its data folders to everyone (777): back to its user's only
    chmod 700 "${CACHE}" "${STORE}" "${FILES}" "${AVATARS}"
    id="$(mysql_bb -e "SELECT user_id FROM ${PREFIX}users WHERE username_clean = '${ADMIN}'" 2>/dev/null)"
    ( umask 077; printf '%s\n' "${id}" > "${ADMIN_ID_FILE}"; printf '%s\n' "${password}" > "${PASSWORD_FILE}" )
    log "installed the board: its administrator is ${ADMIN} (its password is shown on the app's page)"
}

# Sets the board's address in its settings (its links follow it; its cookies are for that host only - no domain), then
# clears its cache so that it's used.
#
# $1 url Its address
#
# Returns 0 once it's set
set_address() {
    protocol="${1%%://*}://"
    rest="${1#*://}"
    host="${rest%%:*}"
    port="${rest#*:}"
    [ "${port}" = "${rest}" ] && port=443 && [ "${protocol}" = 'http://' ] && port=80
    # Secure cookies only when it's reachable over HTTPS alone (the Nginx app's site, LISTEN=local)
    secure=0
    [ "${protocol}" = 'https://' ] && [ "$(setting LISTEN local)" = local ] && secure=1

    mysql_bb <<EOF || return 1
UPDATE ${PREFIX}config SET config_value = '${protocol}' WHERE config_name = 'server_protocol';
UPDATE ${PREFIX}config SET config_value = '${host}' WHERE config_name = 'server_name';
UPDATE ${PREFIX}config SET config_value = '' WHERE config_name = 'cookie_domain';
UPDATE ${PREFIX}config SET config_value = '${port}' WHERE config_name = 'server_port';
UPDATE ${PREFIX}config SET config_value = '1' WHERE config_name = 'force_server_vars';
UPDATE ${PREFIX}config SET config_value = '/' WHERE config_name = 'script_path';
UPDATE ${PREFIX}config SET config_value = '${secure}' WHERE config_name = 'cookie_secure';
EOF
    bb_php bin/phpbbcli.php cache:purge > /dev/null 2>&1
}

# Gives its administrator a password (from the input), hashed as phpBB hashes them (bcrypt), in its database: in use at
# once, its failed logins forgotten.
#
# Returns 0 once it's set
admin_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    id="$(cat "${ADMIN_ID_FILE}" 2>/dev/null)"

    case "${id}" in
        ''|*[!0-9]*) log 'Its administrator has not been set up yet (start phpBB first)'; return 1 ;;
    esac

    hash="$(printf '%s' "${password}" \
        | "${PHP}" -n -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT, ["cost" => 10]);')"

    case "${hash}" in
        '$2y$10$'*) ;;
        *) log 'Could not hash the password (is the PHP app installed?)'; return 1 ;;
    esac

    # A bcrypt hash has no quotes (only letters, digits, . / and $) and the ID was checked, so both go in the SQL as
    # they are
    if ! output="$(mysql_bb -e "UPDATE ${PREFIX}users SET user_password = '${hash}', user_login_attempts = 0
        WHERE user_id = ${id}; SELECT ROW_COUNT();" 2>&1)" || [ "${output}" != 1 ]; then
        log "Could not set its administrator's password: ${output}"

        return 1
    fi

    ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
}

# Whether it's phpBB answering (its board index), while its web server is still running - not something else on the
# port.
#
# Returns 0 once it answers
wait_up() {
    waited=0

    while [ ${waited} -lt 60 ]; do
        running || return 1
        curl -sf -m 5 "http://127.0.0.1:${PORT}/index.php" 2>/dev/null | grep -q 'phpBB' && return 0
        sleep 2
        waited=$((waited + 2))
    done

    return 1
}

start() {
    if running; then
        log "phpBB is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    if [ ! -x "${PHP}" ]; then
        log 'phpBB needs the PHP app (PHP 8.5): install it first'

        return 1
    fi

    setup || return 1

    # Its database and login: made the first time - at boot, MariaDB may start after this app, so it's waited for in
    # the background, then phpBB started
    if [ ! -s "${DB_PASSWORD_FILE}" ] && ! db_login 15; then
        log 'waiting for MariaDB in the background, to set up its database'
        ( sh "${APP_PATH}/phpbb_ctl.sh" later > /dev/null 2>&1 & )

        return 0
    fi

    url="$(app_url)"

    # The board installed the first time; else its database brought up to date (after an update)
    if installed; then
        write_config || { log "Could not write its settings: ${CONFIG_FILE}"; return 1; }

        if ! output="$(bb_php bin/phpbbcli.php db:migrate --safe-mode --no-interaction 2>&1)"; then
            log "Could not update phpBB's database: $(echo "${output}" | tail -n 5)"

            return 1
        fi
    else
        # (phpBB's installer takes a config.php with anything in it as an installed board)
        : > "${CONFIG_FILE}"
        install_board "${url}" || return 1
        write_config || return 1
    fi

    set_address "${url}" || { log "Could not set its address: ${url}"; return 1; }

    set -- $(bb_ids)
    host=127.0.0.1
    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0
    log "starting phpBB on ${host}:${PORT} (${url})"
    cd "${BB}" || return 1
    # PHP's own web server with 4 workers (each request to one of them), the app's router (phpBB's private folders
    # refused); opcache on; uploads up to 100MB (the Nginx app passes any size)
    ( HOME="${CACHE}" PHP_CLI_SERVER_WORKERS=4 exec "${BIN}/phpbb_runas" "$1" "$2" "${PHP}" -n \
        -d memory_limit=256M -d upload_max_filesize=100M -d post_max_size=100M -d max_execution_time=300 \
        -d display_errors=0 -d log_errors=1 -d opcache.enable_cli=1 -d opcache.memory_consumption=64 \
        -d mysqli.default_socket="${SOCKET}" -d date.timezone=UTC \
        -S "${host}:${PORT}" -t "${BB}" "${APP_PATH}/lib/router.php" ) >> "${SERVER_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "phpBB did not start (see ${SERVER_LOG}): $(tail -n 2 "${SERVER_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    log "phpBB started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping phpBB (PID ${pid})"

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

# Backs up phpBB: its database (mariadb-dump / mysqldump, as its own login - a consistent copy while it runs), its
# attachments, avatars and extensions - one archive, root's only, in the backup folder, keeping the newest ones.
# Restored as the app's README says.
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
    work="${dir}/.phpbb-${stamp}"
    file="${dir}/phpbb-${stamp}.tar.gz"
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    if ! output="$(MYSQL_PWD="$(cat "${DB_PASSWORD_FILE}")" "$(mariadb_program mariadb-dump mysqldump)" \
        --socket="${SOCKET}" -u"${DB}" --single-transaction --routines --no-tablespaces "${DB}" \
        2>&1 > "${work}/phpbb.sql")" \
        || ! tail -n 1 "${work}/phpbb.sql" | grep -q 'Dump completed'; then
        log "The database backup failed: ${output}"
        rm -rf "${work}"

        return 1
    fi

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . -C "${DATA_PATH}" files avatars ext ) \
        || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -rf "${work}" "${file}.tmp"

        return 1
    fi

    rm -rf "${work}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/phpbb-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps PHP's web server's log under 1MB (the previous part is kept as server.log.1)
rotate_log() {
    if [ "$(wc -c < "${SERVER_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp -p "${SERVER_LOG}" "${SERVER_LOG}.1" && : > "${SERVER_LOG}"
    fi
}

# The Nginx app finds phpBB by its folder (its nginx.json): rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    later)
        # (Started by start: waits up to 5 minutes for MariaDB, then starts phpBB)
        db_login 300 && start
        ;;
    set-password) admin_password ;;
    backup) backup ;;
    daily) backup; rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|set-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
