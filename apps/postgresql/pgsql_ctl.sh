#!/bin/sh
# Runs PostgreSQL, with its data in the persistent path (Nas_Prog/_postgresql - kept across reinstalls):
#   pgsql_ctl.sh setup          - the postgres user, folders, and (the first time) a new database cluster
#   pgsql_ctl.sh start | stop   - start / stop PostgreSQL (stop disconnects its clients, then shuts down cleanly) - start
#                                 first upgrades data from the previous major version (see upgrade below)
#   pgsql_ctl.sh network on|off - accept connections from the local network (with passwords), or from the NAS only
#   pgsql_ctl.sh preload [extension,...] - the extensions loaded at start-up (pg_cron, pgaudit need it), or none
#
# PostgreSQL refuses to run as root, so it runs as a postgres user with a fixed ID: the NAS's /etc is rebuilt on every
# boot (so the user is added again), and the data belongs to that ID whatever happens to the user's entry.

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_postgresql"
PGDATA="${DATA_PATH}/data"
PGBIN="${APP_PATH}/binaries/postgresql/bin"
# The previous major version's server (only what pg_upgrade runs), to upgrade its data from
PREVIOUS_BIN="${APP_PATH}/binaries/postgresql/previous/bin"
# Why PostgreSQL can't start on its data (an upgrade that couldn't be made) - shown on the app's page
PROBLEM_FILE="${DATA_PATH}/problem"
UPGRADE_PATH="${DATA_PATH}/upgrade"
PG_UID=70
PG_GID=70
SOCKET_DIR=/var/run/postgresql
PASSWORD_FILE="${DATA_PATH}/postgres_password"
UPGRADED=''
MARK_BEGIN='# --- added by the postgresql app ---'
MARK_END="# --- end of the postgresql app's settings ---"
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') postgresql/pgsql_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# PROJ (used by PostGIS) looks for its database of coordinate systems where it was built - so it's told where it is
export PROJ_DATA="${APP_PATH}/binaries/postgresql/share/proj"

# Runs one of PostgreSQL's programs as the postgres user.
#
# $1 program Its name (in ${PGBIN}), or its path
# $@         Its arguments
as_postgres() {
    local program="$1"

    shift

    case "${program}" in
        */*) ;;
        *) program="${PGBIN}/${program}" ;;
    esac

    "${PGBIN}/pg_runas" ${PG_UID} ${PG_GID} "${program}" "$@"
}

# The major version of the PostgreSQL in a folder of programs.
#
# $1 bin The folder
#
# Prints it (e.g. 19), or nothing if there's none
major_of() {
    "$1/postgres" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([0-9]*\).*/\1/p'
}

# Records why PostgreSQL can't start on its data (shown on the app's page), and logs it.
#
# $* The reason
problem() {
    printf '%s\n' "$*" > "${PROBLEM_FILE}"
    log "$*"
}

# Makes a new, empty database cluster as the app always has: PostgreSQL's own UTF-8 locale (the NAS has no system
# locales - ICU collations are there for other languages), and passwords for every connection, the postgres superuser's
# from its password file.
#
# $1 folder The cluster's folder (made here, the postgres user's)
# $@        initdb's other options
#
# Returns 0 once it's made
init_cluster() {
    local folder="$1"
    local pwfile="${DATA_PATH}/.pwfile"
    local result=0

    shift

    # The postgres superuser's password: generated once, readable by root only
    if [ ! -s "${PASSWORD_FILE}" ]; then
        tr -dc A-Za-z0-9 < /dev/urandom | head -c 24 > "${PASSWORD_FILE}"
        chmod 600 "${PASSWORD_FILE}"
    fi

    mkdir -p "${folder}"
    chown ${PG_UID}:${PG_GID} "${folder}"
    chmod 700 "${folder}"
    cp "${PASSWORD_FILE}" "${pwfile}"
    chown ${PG_UID} "${pwfile}"
    as_postgres initdb -D "${folder}" -U postgres --pwfile="${pwfile}" --encoding=UTF8 --locale-provider=builtin \
        --builtin-locale=C.UTF-8 --auth=scram-sha-256 "$@" >> ${LOG} 2>&1 || result=1
    rm -f "${pwfile}"

    return ${result}
}

ensure_user() {
    owner="$(awk -F: -v id=${PG_UID} '$3 == id { print $1 }' /etc/passwd)"

    if [ -n "${owner}" ] && [ "${owner}" != postgres ]; then
        log "User ID ${PG_UID} already belongs to: ${owner} - PostgreSQL needs it for its postgres user"

        return 1
    fi

    grep -q '^postgres:' /etc/group || addgroup -g ${PG_GID} postgres
    grep -q '^postgres:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${PG_UID} -G postgres postgres
}

setup() {
    ensure_user || return 1
    mkdir -p "${DATA_PATH}" "${SOCKET_DIR}"
    chown ${PG_UID}:${PG_GID} "${SOCKET_DIR}"
    chmod 775 "${SOCKET_DIR}"

    if [ ! -s "${PGDATA}/PG_VERSION" ]; then
        log "Creating a new database cluster in: ${PGDATA}"

        if ! init_cluster "${PGDATA}"; then
            log "Creating the database cluster failed - see ${LOG}"

            return 1
        fi

        cat >> "${PGDATA}/postgresql.conf" <<EOF2

${MARK_BEGIN}
listen_addresses = 'localhost'
unix_socket_directories = '${SOCKET_DIR}'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
${MARK_END}
EOF2
    fi

    # The data belongs to the postgres user's ID (e.g. after copying it in)
    [ "$(stat -c %u "${PGDATA}")" = ${PG_UID} ] || chown -R ${PG_UID}:${PG_GID} "${PGDATA}"
}

# Upgrades the data from the previous major version, if it's that version's (a new major version can't use it): with
# pg_upgrade, copying it into a new cluster - the data itself is never changed, and stays as data-<its version>
# (data-18), which the app's page can remove. The new cluster is made as the app makes one, then takes the data's
# settings (postgresql.conf, ALTER SYSTEM's, pg_hba.conf, pg_ident.conf; this version's own postgresql.conf with the
# app's settings if this version refuses them). pg_upgrade connects to both servers through its socket in a folder only
# the postgres user can open, with a settings file of its own allowing that without a password. Only once it has
# worked does the new cluster replace the data; until then (or if it fails) nothing changes, and the reason is shown on
# the app's page.
#
# Returns 0 if the data is (now) this version's
upgrade() {
    local old new previous need free state checksums target file conf

    old="$(cat "${PGDATA}/PG_VERSION")"
    new="$(major_of "${PGBIN}")"

    if [ "${old}" = "${new}" ]; then
        rm -f "${PROBLEM_FILE}"

        return 0
    fi

    previous="$(major_of "${PREVIOUS_BIN}")"

    if [ "${old}" != "${previous}" ]; then
        problem "The data is PostgreSQL ${old}'s: PostgreSQL ${new} can only upgrade data from PostgreSQL" \
            "${previous:-?} - install the app's PostgreSQL ${old} version again to use it"

        return 1
    fi

    # A copy of the data is made: room for it, and some to spare
    need="$(du -sk "${PGDATA}" | cut -f 1)"
    free="$(df -Pk "${DATA_PATH}" | awk 'NR == 2 { print $4 }')"

    # (Compared by the shell's 64-bit arithmetic: the NAS's BusyBox [ ] compares 32-bit numbers, and a big volume's
    # free KB wraps round to a negative number there)
    if [ $((${free:-0} < need + 102400)) -eq 1 ]; then
        problem "Upgrading the data to PostgreSQL ${new} needs $((need / 1024 + 100)) MB free next to it" \
            "(it's copied): only $((free / 1024)) MB are"

        return 1
    fi

    log "Upgrading the data from PostgreSQL ${old} to ${new}"
    rm -rf "${UPGRADE_PATH}" "${PGDATA}.new"
    mkdir -p "${UPGRADE_PATH}"
    chown ${PG_UID}:${PG_GID} "${UPGRADE_PATH}"
    chmod 700 "${UPGRADE_PATH}"
    printf 'local all all trust\n' > "${UPGRADE_PATH}/hba.conf"
    chown ${PG_UID}:${PG_GID} "${UPGRADE_PATH}/hba.conf"

    # pg_upgrade needs it shut down cleanly: if it wasn't (e.g. a power cut), its server recovers it first
    state="$(as_postgres "${PREVIOUS_BIN}/pg_controldata" "${PGDATA}" | sed -n 's/^Database cluster state: *//p')"

    if [ "${state}" != 'shut down' ]; then
        log "The data wasn't shut down cleanly (${state}): PostgreSQL ${old} recovers it first"
        as_postgres "${PREVIOUS_BIN}/pg_ctl" start -D "${PGDATA}" -w -t 600 -l "${UPGRADE_PATH}/recovery.log" \
            -o "-c listen_addresses='' -c unix_socket_directories='${UPGRADE_PATH}'" >> ${LOG} 2>&1
        as_postgres "${PREVIOUS_BIN}/pg_ctl" stop -D "${PGDATA}" -m fast -w -t 120 >> ${LOG} 2>&1
    fi

    # The new cluster: with data checksums as the data has them, or not
    checksums='--no-data-checksums'
    as_postgres "${PREVIOUS_BIN}/pg_controldata" "${PGDATA}" | grep -q '^Data page checksum version: *[1-9]' \
        && checksums='--data-checksums'

    if ! init_cluster "${PGDATA}.new" ${checksums}; then
        problem "Upgrading the data to PostgreSQL ${new} failed: its new cluster couldn't be made - see ${LOG}"
        rm -rf "${PGDATA}.new" "${UPGRADE_PATH}"

        return 1
    fi

    # The data's settings, unless this version refuses them (e.g. one it no longer has): then its own postgresql.conf,
    # with the app's settings from the data's
    for file in postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; do
        cp "${PGDATA}.new/${file}" "${UPGRADE_PATH}/${file}.new" 2>/dev/null
        [ -f "${PGDATA}/${file}" ] && cp "${PGDATA}/${file}" "${PGDATA}.new/${file}"
    done

    chown ${PG_UID}:${PG_GID} "${PGDATA}.new"/*.conf

    if ! as_postgres postgres -D "${PGDATA}.new" -C data_directory > /dev/null 2>> ${LOG}; then
        log "PostgreSQL ${new} refuses some of the data's settings: its own are used, with the app's"
        conf="${PGDATA}.new/postgresql.conf"
        cp "${UPGRADE_PATH}/postgresql.conf.new" "${conf}"
        cp "${UPGRADE_PATH}/postgresql.auto.conf.new" "${PGDATA}.new/postgresql.auto.conf"
        printf '\n' >> "${conf}"
        sed -n "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/p" "${PGDATA}/postgresql.conf" >> "${conf}"
        chown ${PG_UID}:${PG_GID} "${PGDATA}.new"/*.conf
    fi

    # (from its folder: it writes its scripts there - update_extensions.sql among them)
    if ! (cd "${UPGRADE_PATH}" && as_postgres pg_upgrade -b "${PREVIOUS_BIN}" -B "${PGBIN}" -d "${PGDATA}" \
        -D "${PGDATA}.new" -s "${UPGRADE_PATH}" -o "-c hba_file=${UPGRADE_PATH}/hba.conf" \
        -O "-c hba_file=${UPGRADE_PATH}/hba.conf") >> ${LOG} 2>&1; then
        rm -rf "${DATA_PATH}/upgrade-logs"
        cp -r "${PGDATA}.new/pg_upgrade_output.d" "${DATA_PATH}/upgrade-logs" 2>/dev/null
        problem "Upgrading the data to PostgreSQL ${new} failed (the data is unchanged): see ${LOG} and" \
            "${DATA_PATH}/upgrade-logs"
        rm -rf "${PGDATA}.new"

        return 1
    fi

    target="${DATA_PATH}/data-${old}"
    [ -e "${target}" ] && target="${target}-$(date +%Y%m%d-%H%M%S)"
    mv "${PGDATA}" "${target}"
    mv "${PGDATA}.new" "${PGDATA}"
    rm -rf "${DATA_PATH}/upgrade-logs" "${PROBLEM_FILE}"
    log "Upgraded the data to PostgreSQL ${new} - PostgreSQL ${old}'s is kept in: ${target}"
    UPGRADED=yes

    return 0
}

# After an upgrade, once the server runs: the extensions' updates pg_upgrade lists (update_extensions.sql), then the
# planner's statistics it couldn't carry over (in the background - large databases take a while). Problems are logged.
after_upgrade() {
    local password

    password="$(cat "${PASSWORD_FILE}")"

    if [ -s "${UPGRADE_PATH}/update_extensions.sql" ]; then
        PGPASSWORD="${password}" "${PGBIN}/psql" -h "${SOCKET_DIR}" -U postgres -d postgres -X -q \
            -f "${UPGRADE_PATH}/update_extensions.sql" >> ${LOG} 2>&1 \
            && log "Updated the extensions" || log "Updating the extensions failed: see ${LOG}"
    fi

    rm -rf "${UPGRADE_PATH}"
    (PGPASSWORD="${password}" "${PGBIN}/vacuumdb" -h "${SOCKET_DIR}" -U postgres --all --analyze-in-stages \
        --missing-stats-only >> ${LOG} 2>&1 &)
}

running() {
    as_postgres pg_ctl status -D "${PGDATA}" > /dev/null 2>&1
}

start() {
    setup || return 1
    upgrade || return 1

    if running; then
        log 'PostgreSQL is already running'

        return 0
    fi

    # The log folder PostgreSQL logs to once running - its start-up messages go there too
    mkdir -p "${PGDATA}/log"
    chown ${PG_UID}:${PG_GID} "${PGDATA}/log"

    if as_postgres pg_ctl start -D "${PGDATA}" -w -t 60 -l "${PGDATA}/log/startup.log" >> ${LOG} 2>&1; then
        log 'PostgreSQL started'

        if [ -n "${UPGRADED}" ]; then
            after_upgrade
        fi
    else
        log "PostgreSQL could not start - see ${PGDATA}/log/startup.log"

        return 1
    fi
}

stop() {
    running || return 0
    # fast: disconnects clients (rolling back their transactions) and shuts down cleanly
    as_postgres pg_ctl stop -D "${PGDATA}" -m fast -w -t 60 >> ${LOG} 2>&1 && log 'PostgreSQL stopped'
}

# Connections from the local network (password protected) on, or off (the NAS only): listen_addresses, plus a line in
# pg_hba.conf for the NAS's own networks (samenet), between the app's markers. PostgreSQL restarts to apply it
network() {
    conf="${PGDATA}/postgresql.conf"
    hba="${PGDATA}/pg_hba.conf"

    sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/s/^listen_addresses = .*/listen_addresses = '$([ "$1" = on ] && echo '*' || echo localhost)'/" "${conf}"
    sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "${hba}"

    if [ "$1" = on ]; then
        printf '%s\nhost    all             all             samenet                 scram-sha-256\n%s\n' "${MARK_BEGIN}" "${MARK_END}" >> "${hba}"
    fi

    stop && start
}

# The extensions loaded at start-up (shared_preload_libraries, in the app's settings): pg_cron runs its jobs from the
# postgres database. PostgreSQL restarts to apply it
preload() {
    conf="${PGDATA}/postgresql.conf"

    case "$1" in *[!a-z_,]*) log "Not an extension list: $1"; return 1 ;; esac
    cron=''

    case ",$1," in *,pg_cron,*) cron=yes ;; esac
    # Rewritten with awk: the settings go just before the end marker, replacing any from before
    awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" -v list="$1" -v cron="${cron}" '
		$0 == begin { inside = 1 }
		inside && /^(shared_preload_libraries|cron\.database_name) = / { next }
		$0 == end && inside {
			if (list != "") print "shared_preload_libraries = \047" list "\047"
			if (cron != "") print "cron.database_name = \047postgres\047"
			inside = 0
		}
		{ print }
	' "${conf}" > "${conf}.tmp" && cat "${conf}.tmp" > "${conf}" && rm -f "${conf}.tmp"
    stop && start
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    network) network "$2" ;;
    preload) preload "$2" ;;
    *) echo "Usage: $0 setup | start | stop | network on|off | preload [extension,...]"; exit 1 ;;
esac
