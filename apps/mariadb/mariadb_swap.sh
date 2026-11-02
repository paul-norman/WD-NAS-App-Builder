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
MARK_BEGIN='# --- added by the mariadb app ---'
MARK_END="# --- end of the mariadb app's settings ---"
LOG=/tmp/debug_apkg

# WD's own MariaDB lock (mysql_reset.py takes it too), so that both never change MariaDB at the same time: waits up to
# 10 minutes for it
take_lock() {
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

# Starts the server with WD's own startup-mysql, waiting until it answers. (Not with the lock open: the server would
# keep holding it - blocking WD's own mysql_reset.py too)
start_server() {
    startup-mysql 9>&- > /dev/null 2>&1 &
    waited=0

    until mysql --socket="${SOCKET}" -uroot -e 'SELECT 1' > /dev/null 2>&1; do
        if [ ${waited} -ge 60 ]; then
            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done
}

server_version() {
    mysql --socket="${SOCKET}" -uroot -N -e 'SELECT VERSION()' 2>/dev/null
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

# Puts WD's MariaDB 10.5 back, apart from starting it
restore_now() {
    ln -sf "${WD_SERVER}" /usr/libexec/mariadbd
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

    # WD's data folder: from the running server the first time
    mkdir -p "${DATA_PATH}"

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

    # The data is upgraded once (and recorded under the name WD's mysql_reset.py looks for too, so that it doesn't try
    # to upgrade it with 10.5's tools), then the server restarts with its upgraded system tables
    if [ "$(cut -d - -f 1 "${COPY}/mysql_upgrade_info" 2>/dev/null)" != "${VERSION}" ]; then
        log "Upgrading the data for MariaDB ${VERSION}"

        if ! /usr/local/mysql/bin/mariadb-upgrade --socket="${SOCKET}" -uroot >> ${LOG} 2>&1; then
            log "Upgrading the data failed - see ${LOG}. If WD's data is too inconsistent for ${VERSION}, '$0 fresh' starts again with new, empty system tables"

            return 1
        fi

        server_version > "${COPY}/mysql_upgrade_info"
        stop_server && start_server
    fi

    log "MariaDB $(server_version) is running"
}

restore() {
    take_lock || return 1
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

    grep -q " ${datadir} " /proc/mounts && umount "${datadir}"
    old="${COPY}.old-$(date '+%Y%m%d-%H%M%S')"
    [ -d "${COPY}" ] && mv "${COPY}" "${old}" && log "Kept the previous data as: ${old}"
    log "Creating new system tables in: ${COPY}"

    if ! /usr/local/mysql/scripts/mariadb-install-db --basedir=/usr/local/mysql --datadir="${COPY}" --user=root \
        --auth-root-authentication-method=normal --skip-test-db >> ${LOG} 2>&1; then
        log "Creating the system tables failed - see ${LOG}"
        rm -rf "${COPY}"
        [ -n "${old}" ] && [ -d "${old}" ] && mv "${old}" "${COPY}"
        mount --bind "${COPY}" "${datadir}"
        start_server

        return 1
    fi

    mount --bind "${COPY}" "${datadir}"
    start_server || { log "MariaDB ${VERSION} didn't start on the new system tables (see ${COPY}/*.err)"; return 1; }
    server_version > "${COPY}/mysql_upgrade_info"
    log "MariaDB $(server_version) is running with new system tables"
}

status() {
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
