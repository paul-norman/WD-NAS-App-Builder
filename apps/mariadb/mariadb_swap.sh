#!/bin/sh
# Makes MariaDB 11.8 the NAS's own MariaDB in place of WD's 10.5 - and back again - underneath WD's own way of running
# it (startup-mysql starts /usr/bin/mysqld_safe, which runs /usr/libexec/mariadbd; mysql_reset.py stops it with killall
# and finds its data folder in ps), so WD's scripts keep working. / and /etc are in RAM, so this is applied on every
# boot (start.sh):
#   - /usr/local/mysql links to the app's MariaDB (where MariaDB's release looks for its plugins, messages and
#     character sets - and its server for the stand-in libsystemd), and /usr/libexec/mariadbd to its server
#   - a copy of WD's data (Nas_Prog/_mariadb/data, made once) is mounted over WD's data folder, which stays untouched:
#     11.8 converts the data it runs on, and 10.5 couldn't read it afterwards
#   - /etc/my.cnf gets 11.8's own settings, in a [mariadb-11.8] group that 10.5 doesn't read
#
# On a NAS without WD's MariaDB (no startup-mysql or WD's server: perhaps some ARM models), the app runs MariaDB by
# itself instead ("own" mode, chosen and remembered on the first swap): on its own data (Nas_Prog/_mariadb/data, new),
# started and stopped by the app, as /usr/libexec/mariadbd and where WD's would listen (the NAS only, socket
# /var/lib/mysql/mysql.sock, port 3306, root without a password) - so apps find it just as they find WD's.
#
#   mariadb_swap.sh swap      - switch to MariaDB 11.8
#   mariadb_swap.sh restore   - switch back to WD's MariaDB 10.5 (with its own, untouched data)
#   mariadb_swap.sh status    - which MariaDB is running
#   mariadb_swap.sh fresh     - start 11.8 again with new, empty system tables instead of WD's data (which can be too
#                               inconsistent for 11.8, e.g. after starting life on MySQL 5.1) - the old copy is kept

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_mariadb"
COPY="${DATA_PATH}/data"
MARIADB="${APP_PATH}/binaries/mariadb"
# MariaDB's version: the app's without its packaging revision, e.g. 11.8.9-1
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
SERIES="${VERSION%.*}"
WD_SERVER=/usr/local/modules/mysql/libexec/mariadbd
SOCKET=/var/lib/mysql/mysql.sock
MY_CNF=/etc/my.cnf
MODE_FILE="${DATA_PATH}/mode"
MARK_BEGIN='# --- added by the mariadb app ---'
MARK_END="# --- end of the mariadb app's settings ---"
LOG=/tmp/debug_apkg

# WD's own MariaDB lock (mysql_reset.py takes it too), so that both never change MariaDB at the same time: waits up to
# 10 minutes for it
take_lock() {
    mkdir -p /run/lock
    exec 9> /run/lock/mysql_reset.py.lock
    waited=0

    until flock -n 9; do
        if [ ${waited} -ge 600 ]; then
            log "WD's MariaDB lock wasn't released within 10 minutes"

            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done
}

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') mariadb/mariadb_swap.sh $*" >> ${LOG}
    echo "$*"
}

# The running server's data folder - found the way WD's mysql_reset.py does (from ps)
running_datadir() {
    ps -aux 2>/dev/null | grep datadir | awk -F'/usr/libexec/mariadbd' 'NF > 1 { split($2, a, "--datadir="); split(a[2], b, " "); print b[1]; exit }'
}

# Whether the NAS has WD's own MariaDB: its startup-mysql and its server.
wd_has_mariadb() {
    command -v startup-mysql > /dev/null 2>&1 && [ -x "${WD_SERVER}" ]
}

# How the app runs MariaDB, as chosen on its first swap: wd (underneath WD's own) or own (by itself).
#
# Prints the mode
mode() {
    cat "${MODE_FILE}" 2>/dev/null || echo wd
}

# Runs a client (WD's, else the app's) with its arguments.
#
# $@ The client's arguments
client() {
    if command -v mysql > /dev/null 2>&1; then
        mysql "$@"
    else
        /usr/local/mysql/bin/mariadb "$@"
    fi
}

server_running() {
    pidof mariadbd > /dev/null 2>&1 || pidof mysqld > /dev/null 2>&1
}

# WD's data folder: remembered from the first swap (when it's found from the running server)
wd_datadir() {
    cat "${DATA_PATH}/wd_datadir" 2>/dev/null
}

# Stops the server as WD's mysql_reset.py does, waiting for InnoDB to shut down cleanly
stop_server() {
    server_running || return 0
    killall mysqld mysqld_safe mariadbd mariadbd-safe 2>/dev/null
    waited=0

    while server_running; do
        if [ ${waited} -ge 120 ]; then
            log 'MariaDB did not stop within 2 minutes'

            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done
}

# Starts the server - with WD's own startup-mysql, or in own mode by itself (as /usr/libexec/mariadbd, as WD's would
# run) - waiting until it answers. (Not with the lock open: the server would keep holding it - blocking WD's own
# mysql_reset.py too)
start_server() {
    if [ "$(mode)" = own ]; then
        mkdir -p "$(dirname "${SOCKET}")"
        /usr/libexec/mariadbd --basedir=/usr/local/mysql --datadir="${COPY}" --user=root --socket="${SOCKET}" \
            --bind-address=127.0.0.1 --port=3306 --pid-file="${COPY}/mariadb.pid" --log-error="${COPY}/mariadb.err" \
            9>&- > /dev/null 2>&1 &
    else
        startup-mysql 9>&- > /dev/null 2>&1 &
    fi

    waited=0

    until client --socket="${SOCKET}" -uroot -e 'SELECT 1' > /dev/null 2>&1; do
        if [ ${waited} -ge 60 ]; then
            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done
}

server_version() {
    client --socket="${SOCKET}" -uroot -N -e 'SELECT VERSION()' 2>/dev/null
}

# New, empty system tables in the folder given, with root without a password as WD's scripts expect.
#
# $1 folder The data folder
new_datadir() {
    log "Creating new system tables in: $1"

    if ! /usr/local/mysql/scripts/mariadb-install-db --basedir=/usr/local/mysql --datadir="$1" --user=root \
        --auth-root-authentication-method=normal --skip-test-db >> ${LOG} 2>&1; then
        log "Creating the system tables failed - see ${LOG}"
        rm -rf "$1"

        return 1
    fi

    # Made by this version: nothing to upgrade
    echo "${VERSION}-MariaDB" > "$1/mysql_upgrade_info"
}

configure_cnf() {
    unconfigure_cnf
    # WD's mysql_reset.py creates it from its own copy when missing
    [ -f "${MY_CNF}" ] || cp /usr/local/modules/etc/my.cnf "${MY_CNF}" 2>/dev/null || touch "${MY_CNF}"
    # WD's 10.5 has its socket built in, where MariaDB's release defaults to /tmp/mysql.sock - the client tools too
    cat >> "${MY_CNF}" <<EOF2
${MARK_BEGIN}
[mariadb-${SERIES}]
socket=${SOCKET}
lc_messages_dir=/usr/local/mysql/share
character_sets_dir=/usr/local/mysql/share/charsets
[client]
socket=${SOCKET}
${MARK_END}
EOF2
}

unconfigure_cnf() {
    [ -f "${MY_CNF}" ] && sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "${MY_CNF}"
}

# Puts WD's MariaDB 10.5 back, apart from starting it (in own mode: takes the app's MariaDB away)
restore_now() {
    if [ "$(mode)" = own ]; then
        [ "$(readlink /usr/libexec/mariadbd)" = /usr/local/mysql/bin/mariadbd ] && rm -f /usr/libexec/mariadbd
    else
        ln -sf "${WD_SERVER}" /usr/libexec/mariadbd
    fi

    datadir="$(wd_datadir)"

    if [ -n "${datadir}" ] && grep -q " ${datadir} " /proc/mounts; then
        umount "${datadir}" 2>/dev/null || umount -l "${datadir}"
    fi

    unconfigure_cnf
    [ "$(readlink /usr/local/mysql)" = "${MARIADB}" ] && rm -f /usr/local/mysql
}

swap() {
    if [ -e /usr/local/mysql ] && [ "$(readlink /usr/local/mysql)" != "${MARIADB}" ]; then
        log "Not switching to MariaDB ${VERSION}: /usr/local/mysql already exists (something else uses it)"

        return 1
    fi

    ln -sfn "${MARIADB}" /usr/local/mysql

    if ! /usr/local/mysql/bin/mariadbd --version > /dev/null 2>&1; then
        log "Not switching to MariaDB ${VERSION}: its server doesn't run on this NAS ($(/usr/local/mysql/bin/mariadbd --version 2>&1 | head -n 1))"
        rm -f /usr/local/mysql

        return 1
    fi

    take_lock || return 1
    mkdir -p "${DATA_PATH}"

    # The mode, chosen once: underneath WD's MariaDB if the NAS has it, else by itself
    if [ ! -f "${MODE_FILE}" ]; then
        if wd_has_mariadb; then
            echo wd > "${MODE_FILE}"
        else
            log "The NAS has no MariaDB of its own (no startup-mysql), so the app runs MariaDB ${VERSION} by itself"
            echo own > "${MODE_FILE}"
        fi
    fi

    if [ "$(mode)" = own ]; then
        swap_own

        return $?
    fi

    # WD's data folder: from the running server the first time

    if [ -z "$(wd_datadir)" ]; then
        datadir="$(running_datadir)"

        if [ -z "${datadir}" ] || [ ! -d "${datadir}" ]; then
            log "Not switching to MariaDB ${VERSION}: WD's MariaDB isn't running, so its data folder isn't known"

            return 1
        fi

        echo "${datadir}" > "${DATA_PATH}/wd_datadir"
    fi

    datadir="$(wd_datadir)"

    log "Stopping WD's MariaDB"
    stop_server || return 1

    # The copy of WD's data that 11.8 runs on (made once - delete it to start again from WD's data)
    if [ ! -d "${COPY}" ]; then
        log "Copying WD's MariaDB data from: ${datadir} to: ${COPY}"

        if ! cp -a "${datadir}" "${COPY}.tmp" || ! mv "${COPY}.tmp" "${COPY}"; then
            log "Not switching to MariaDB ${VERSION}: WD's data couldn't be copied"
            rm -rf "${COPY}.tmp"
            restore_now
            start_server

            return 1
        fi
    fi

    grep -q " ${datadir} " /proc/mounts || mount --bind "${COPY}" "${datadir}"
    configure_cnf
    ln -sf /usr/local/mysql/bin/mariadbd /usr/libexec/mariadbd

    log "Starting MariaDB ${VERSION}"

    if ! start_server || [ "$(server_version | cut -d - -f 1)" != "${VERSION}" ]; then
        log "MariaDB ${VERSION} didn't start (see ${COPY}/*.err), so switching back to WD's"
        stop_server
        restore_now
        start_server

        return 1
    fi

    upgrade
}

# The data is upgraded once for each version (and recorded under the name WD's mysql_reset.py looks for too, so that it
# doesn't try to upgrade it with 10.5's tools), then the server restarts with its upgraded system tables
upgrade() {
    upgraded=yes

    if [ "$(cut -d - -f 1 "${COPY}/mysql_upgrade_info" 2>/dev/null)" != "${VERSION}" ]; then
        log "Upgrading the data for MariaDB ${VERSION}"

        if /usr/local/mysql/bin/mariadb-upgrade --socket="${SOCKET}" -uroot >> ${LOG} 2>&1; then
            server_version > "${COPY}/mysql_upgrade_info"
            stop_server && start_server
        else
            log "Upgrading the data failed - see ${LOG}"
            upgraded=''
        fi
    fi

    # WD's data can have an inconsistent catalogue (e.g. having started life on an older MySQL): system tables listed
    # whose files are missing, which MariaDB then can't use (and its upgrade may fail on). Then they're rebuilt, the
    # databases and users carried over
    if [ -z "${upgraded}" ] || ! system_tables_usable; then
        rebuild || return 1
    fi

    log "MariaDB $(server_version) is running"
}

# Whether the system tables InnoDB keeps (statistics, the transaction registry) can be used: missing from an
# inconsistent catalogue, they can't.
system_tables_usable() {
    for table in innodb_table_stats innodb_index_stats transaction_registry; do
        /usr/local/mysql/bin/mariadb --socket="${SOCKET}" -uroot -N -e "SELECT 1 FROM mysql.${table} LIMIT 1" \
            > /dev/null 2>&1 || return 1
    done
}

# New, consistent system tables in place of those of the copy of WD's data, with its databases and users carried over:
# both dumped from the running server, the copy kept (data.old-<date>), new system tables made, then the dump loaded.
# Anything failing puts the copy back as it was. The page shows that it was done (rebuilt).
rebuild() {
    dump="${DATA_PATH}/rebuild.sql"
    tools=/usr/local/mysql/bin
    log "The copy of WD's MariaDB data has an inconsistent catalogue (system tables missing): rebuilding its system tables, carrying its databases and users over"
    databases="$(${tools}/mariadb --socket="${SOCKET}" -uroot -N -e "SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')" 2>> ${LOG})"

    # (root's only: it holds the users' password hashes. Users other than those the new system tables have - root:
    # CREATE USER IF NOT EXISTS)
    : > "${dump}"
    chmod 600 "${dump}"

    if ! { ${tools}/mariadb-dump --socket="${SOCKET}" -uroot --system=users --insert-ignore \
        && { [ -z "${databases}" ] || ${tools}/mariadb-dump --socket="${SOCKET}" -uroot --routines --events \
            --triggers --single-transaction --databases ${databases}; }; } > "${dump}" 2>> ${LOG}; then
        log "Couldn't dump the databases and users to rebuild the system tables - see ${LOG}. '$0 fresh' starts again with new, empty system tables"
        rm -f "${dump}"

        return 1
    fi

    datadir="$(wd_datadir)"
    old="${COPY}.old-$(date '+%Y%m%d-%H%M%S')"
    stop_server || return 1
    [ "$(mode)" = wd ] && grep -q " ${datadir} " /proc/mounts && umount "${datadir}"
    mv "${COPY}" "${old}"

    if new_datadir "${COPY}"; then
        [ "$(mode)" = wd ] && mount --bind "${COPY}" "${datadir}"

        if start_server && ${tools}/mariadb --socket="${SOCKET}" -uroot < "${dump}" >> ${LOG} 2>&1; then
            rm -f "${dump}"
            echo "$(date '+%Y-%m-%d %H:%M:%S') ${old}" > "${DATA_PATH}/rebuilt"
            log "Rebuilt the system tables, with the databases (${databases:-none of the user's}) and users carried over - the previous copy is kept as: ${old}"

            return 0
        fi

        stop_server
        [ "$(mode)" = wd ] && grep -q " ${datadir} " /proc/mounts && umount "${datadir}"
    fi

    log "Rebuilding the system tables failed - see ${LOG}: back to the copy as it was"
    rm -rf "${COPY}"
    mv "${old}" "${COPY}"
    [ "$(mode)" = wd ] && mount --bind "${COPY}" "${datadir}"
    start_server

    return 1
}

# Own mode's swap: the app's MariaDB as /usr/libexec/mariadbd, on its own data (new the first time).
swap_own() {
    mkdir -p /usr/libexec
    stop_server || return 1
    configure_cnf
    ln -sf /usr/local/mysql/bin/mariadbd /usr/libexec/mariadbd

    if [ ! -d "${COPY}" ] && ! new_datadir "${COPY}"; then
        restore_now

        return 1
    fi

    log "Starting MariaDB ${VERSION}"

    if ! start_server || [ "$(server_version | cut -d - -f 1)" != "${VERSION}" ]; then
        log "MariaDB ${VERSION} didn't start (see ${COPY}/mariadb.err)"
        stop_server
        restore_now

        return 1
    fi

    upgrade
}

restore() {
    take_lock || return 1

    if [ "$(mode)" = own ]; then
        stop_server
        restore_now
        log 'Stopped MariaDB (the NAS has no MariaDB of its own to switch back to)'

        return 0
    fi

    was_running=''
    server_running && was_running=yes
    stop_server
    restore_now
    log "Switched back to WD's MariaDB"

    if [ -n "${was_running}" ]; then
        start_server && log "WD's MariaDB $(server_version) is running"
    fi
}

# New, empty system tables for 11.8 in place of the copy of WD's data (kept as data.old-<date>), with root without a
# password as WD's scripts expect
fresh() {
    if [ "$(readlink /usr/local/mysql)" != "${MARIADB}" ]; then
        log "Switch to MariaDB ${VERSION} first (enable the app)"

        return 1
    fi

    take_lock || return 1

    datadir="$(wd_datadir)"

    stop_server || return 1

    [ "$(mode)" = wd ] && grep -q " ${datadir} " /proc/mounts && umount "${datadir}"
    old="${COPY}.old-$(date '+%Y%m%d-%H%M%S')"
    [ -d "${COPY}" ] && mv "${COPY}" "${old}" && log "Kept the previous data as: ${old}"

    if ! new_datadir "${COPY}"; then
        [ -n "${old}" ] && [ -d "${old}" ] && mv "${old}" "${COPY}"
        [ "$(mode)" = wd ] && mount --bind "${COPY}" "${datadir}"
        start_server

        return 1
    fi

    [ "$(mode)" = wd ] && mount --bind "${COPY}" "${datadir}"
    start_server || { log "MariaDB ${VERSION} didn't start on the new system tables (see ${COPY}/*.err)"; return 1; }
    log "MariaDB $(server_version) is running with new system tables"
}

status() {
    echo "Mode: $(mode) ($([ "$(mode)" = own ] && echo 'by itself: the NAS has no MariaDB of its own' || echo "underneath WD's"))"
    echo "Running: $(server_version || echo 'not running')"
    echo "Server: $(readlink /usr/libexec/mariadbd)"
    echo "Data: $(running_datadir) (WD's: $(wd_datadir), copy: ${COPY})"
}

case "$1" in
    swap) swap ;;
    restore) restore ;;
    status) status ;;
    fresh) fresh ;;
    *) echo "Usage: $0 swap | restore | status | fresh"; exit 1 ;;
esac
