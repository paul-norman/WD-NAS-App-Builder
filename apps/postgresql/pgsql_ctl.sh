#!/bin/sh
# Runs PostgreSQL, with its data in the persistent path (Nas_Prog/_postgresql - kept across reinstalls):
#   pgsql_ctl.sh setup          - the postgres user, folders, and (the first time) a new database cluster
#   pgsql_ctl.sh start | stop   - start / stop PostgreSQL (stop lets running queries finish, then disconnects)
#   pgsql_ctl.sh network on|off - accept connections from the local network (with passwords), or from the NAS only
#   pgsql_ctl.sh preload [extension,...] - the extensions loaded at start-up (pg_cron, pgaudit need it), or none
#
# PostgreSQL refuses to run as root, so it runs as a postgres user with a fixed ID: the NAS's /etc is rebuilt on every
# boot (so the user is added again), and the data belongs to that ID whatever happens to the user's entry.

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_postgresql"
PGDATA="${DATA_PATH}/data"
PGBIN="${APP_PATH}/binaries/postgresql/bin"
PG_UID=70
PG_GID=70
SOCKET_DIR=/var/run/postgresql
PASSWORD_FILE="${DATA_PATH}/postgres_password"
MARK_BEGIN="# --- added by the postgresql app ---"
MARK_END="# --- end of the postgresql app's settings ---"
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') postgresql/pgsql_ctl.sh $*" >> ${LOG}
	echo "$*"
}

# PROJ (used by PostGIS) looks for its database of coordinate systems where it was built - so it's told where it is
export PROJ_DATA="${APP_PATH}/binaries/postgresql/share/proj"

# Runs one of PostgreSQL's programs as the postgres user
as_postgres() {
	program="$1"
	shift
	"${PGBIN}/pg_runas" ${PG_UID} ${PG_GID} "${PGBIN}/${program}" "$@"
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
		# The postgres superuser's password: generated once, readable by root only
		if [ ! -s "${PASSWORD_FILE}" ]; then
			tr -dc A-Za-z0-9 < /dev/urandom | head -c 24 > "${PASSWORD_FILE}"
			chmod 600 "${PASSWORD_FILE}"
		fi
		log "Creating a new database cluster in: ${PGDATA}"
		mkdir -p "${PGDATA}"
		chown ${PG_UID}:${PG_GID} "${PGDATA}"
		chmod 700 "${PGDATA}"
		pwfile="${DATA_PATH}/.pwfile"
		cp "${PASSWORD_FILE}" "${pwfile}"
		chown ${PG_UID} "${pwfile}"
		# PostgreSQL's own UTF-8 locale (the NAS has no system locales - ICU collations are there for other languages),
		# and passwords for every connection
		if ! as_postgres initdb -D "${PGDATA}" -U postgres --pwfile="${pwfile}" --encoding=UTF8 \
			--locale-provider=builtin --builtin-locale=C.UTF-8 --auth=scram-sha-256 >> ${LOG} 2>&1; then
			log "Creating the database cluster failed - see ${LOG}"
			rm -f "${pwfile}"
			return 1
		fi
		rm -f "${pwfile}"
		cat >> "${PGDATA}/postgresql.conf" <<-EOF2

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

running() {
	as_postgres pg_ctl status -D "${PGDATA}" > /dev/null 2>&1
}

start() {
	setup || return 1
	if running; then
		log "PostgreSQL is already running"
		return 0
	fi
	# (the log folder PostgreSQL logs to once running - its start-up messages go there too)
	mkdir -p "${PGDATA}/log"
	chown ${PG_UID}:${PG_GID} "${PGDATA}/log"
	if as_postgres pg_ctl start -D "${PGDATA}" -w -t 60 -l "${PGDATA}/log/startup.log" >> ${LOG} 2>&1; then
		log "PostgreSQL started"
	else
		log "PostgreSQL could not start - see ${PGDATA}/log/startup.log"
		return 1
	fi
}

stop() {
	running || return 0
	# fast: disconnects clients (rolling back their transactions) and shuts down cleanly
	as_postgres pg_ctl stop -D "${PGDATA}" -m fast -w -t 60 >> ${LOG} 2>&1 && log "PostgreSQL stopped"
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
	cron=""
	case ",$1," in *,pg_cron,*) cron=yes ;; esac
	# (rewritten with awk: the settings go just before the end marker, replacing any from before)
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
