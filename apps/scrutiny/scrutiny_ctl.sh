#!/bin/sh
# Runs Scrutiny (the disks' SMART health, with history and alerts): its web interface and InfluxDB (where it keeps the
# history) as its own user, on the NAS itself only - reached through the Nginx app, which asks for the app's login - and
# its collector as root (reading SMART data needs it). Its data is in the persistent path Nas_Prog/_scrutiny - kept
# across reinstalls. Run by the app's scripts, its management page and cron:
#   scrutiny_ctl.sh setup        - create its user, folders and password (where missing)
#   scrutiny_ctl.sh start        - write its settings, start InfluxDB, then Scrutiny (port 8091)
#   scrutiny_ctl.sh stop         - stop both
#   scrutiny_ctl.sh restart      - stop, then start
#   scrutiny_ctl.sh collect      - read the disks' SMART data and send it to Scrutiny (hourly, from root's crontab:
#                                  sleeping disks are left asleep)
#   scrutiny_ctl.sh new-password - generate a new password for its site in the Nginx app
#   scrutiny_ctl.sh daily        - the daily job: keeping its logs small
#   scrutiny_ctl.sh nginx        - add / update Scrutiny's site in the Nginx app (and reload it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_scrutiny"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
# The login for its site in the Nginx app (its nginx.json's auth_file): Scrutiny has no login of its own
HTPASSWD="${DATA_PATH}/htpasswd"
CONFIG="${DATA_PATH}/scrutiny.yaml"
COLLECTOR_CONFIG="${DATA_PATH}/collector.yaml"
WEB_LOG="${DATA_PATH}/scrutiny.log"
INFLUX_LOG="${DATA_PATH}/influxd.log"
COLLECTOR_LOG="${DATA_PATH}/collector.log"
WEB_PID=/var/run/scrutiny.pid
INFLUX_PID=/var/run/scrutiny-influxd.pid
PORT=8091
INFLUX_PORT=8093
# Its own user and group (created if missing): the IDs used when creating them
SCRUTINY_ID=65
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') scrutiny/scrutiny_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. NTFY_TOPIC)
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

# The scrutiny user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
scrutiny_ids() {
    awk -F: '$1 == "scrutiny" { print $3 " " $4 }' /etc/passwd
}

# The group Nginx's worker processes run as: nobody's own (nogroup on Debian - WD's NAS has none by that name: there it's
# the share users' group), by its ID, as the Nginx app picks it.
#
# Prints the group ID
nginx_gid() {
    awk -F: '$1 == "nobody" { print $4 }' /etc/passwd
}

# Writes the htpasswd file for the Nginx app's site: user admin with the app's password, as SHA-512 crypt (Nginx checks
# it on every request, so not a slow hash like bcrypt). Root's, readable by Nginx's workers (their group).
#
# Returns 0 once it's written
write_htpasswd() {
    local hash gid

    gid="$(nginx_gid)"

    if [ -z "${gid}" ]; then
        log "No nobody user on the NAS: Nginx's workers couldn't read the password file"

        return 1
    fi

    hash="$(php -n -r '$salt = substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16);
        echo crypt(trim((string)file_get_contents($argv[1])), "\$6\$rounds=5000\$" . $salt . "\$");' "${PASSWORD_FILE}")"

    case "${hash}" in
        '$6$'*) ;;
        *) log 'Could not hash the password for the Nginx site (is PHP working?)'; return 1 ;;
    esac

    printf 'admin:%s\n' "${hash}" > "${HTPASSWD}.tmp" && chgrp "${gid}" "${HTPASSWD}.tmp" && chmod 640 "${HTPASSWD}.tmp" \
        && mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

# Makes a new password (letters and digits), root's only, and the Nginx site's copy of it.
#
# Prints nothing
new_password() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    log 'generated a new password'
    write_htpasswd
}

setup() {
    local file

    # Its own group and user (the NAS's user list is in RAM, so this is redone at every boot)
    if ! grep -q '^scrutiny:' /etc/group; then
        addgroup -g ${SCRUTINY_ID} scrutiny 2>/dev/null || addgroup -S scrutiny
    fi

    if ! grep -q '^scrutiny:' /etc/passwd; then
        adduser -D -H -h /nonexistent -s /bin/false -u ${SCRUTINY_ID} -G scrutiny scrutiny
    fi

    if [ -z "$(scrutiny_ids)" ]; then
        log "Could not create the scrutiny user (is ID ${SCRUTINY_ID} already taken?)"

        return 1
    fi

    set -- $(scrutiny_ids)

    # Its own data (its database and InfluxDB's) belongs to its user; the settings, the password and the collector's
    # files to root. Its folder is passable for Nginx's workers (to read the htpasswd file)
    mkdir -p "${DATA_PATH}/db" "${DATA_PATH}/influxdb"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${DATA_PATH}/db" "${DATA_PATH}/influxdb"
    chmod 700 "${DATA_PATH}/db" "${DATA_PATH}/influxdb"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        printf 'NTFY_TOPIC=\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password

    # The Nginx site's copy of the login (made again if the password is newer)
    if [ ! -s "${HTPASSWD}" ] || [ "${PASSWORD_FILE}" -nt "${HTPASSWD}" ]; then
        write_htpasswd
    fi

    for file in "${WEB_LOG}" "${INFLUX_LOG}" "${COLLECTOR_LOG}"; do
        touch "${file}"
        chmod 600 "${file}"
    done
}

# Writes Scrutiny's configuration (root's, readable by its group): on the NAS itself only, its databases, and its alerts
# - to the ntfy app's topic, if one is set and the ntfy app is installed (with the token ntfy keeps for the apps).
#
# Prints nothing
write_config() {
    local topic token notify=''

    topic="$(setting NTFY_TOPIC '')"
    token="$(cat "${APPS_PATH}/_ntfy/token" 2>/dev/null)"

    if [ -n "${topic}" ] && [ -n "${token}" ] && [ -d "${APPS_PATH}/ntfy" ]; then
        notify="$(printf '    - "ntfy://:%s@127.0.0.1:2586/%s?scheme=http&title=Scrutiny"' "${token}" "${topic}")"
    fi

    set -- $(scrutiny_ids)
    # (missed uploads aren't alerts: sleeping disks are left asleep, so a disk may go unread for a while)
    cat > "${CONFIG}.tmp" <<EOF
# Written by the app at every start (see scrutiny_ctl.sh) - changes here are lost
version: 1
web:
  listen:
    host: 127.0.0.1
    port: ${PORT}
    basepath: ''
  database:
    location: ${DATA_PATH}/db/scrutiny.db
  src:
    frontend:
      path: ${BIN}/web/dist
  influxdb:
    scheme: http
    host: 127.0.0.1
    port: ${INFLUX_PORT}
    retention_policy: true
log:
  level: WARN
notify:
  on_missed_upload: false
  urls:
${notify:-    []}
EOF
    # (an empty list on its own line isn't YAML: put it after urls:)
    sed -i '/^  urls:$/{N;s/\n    \[\]/ []/}' "${CONFIG}.tmp"
    chgrp "$2" "${CONFIG}.tmp" && chmod 640 "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

# Waits for something to answer on a URL.
#
# $1 url     The URL
# $2 seconds How long to wait at most
#
# Returns 0 once it answers
wait_for() {
    local waited=0

    until curl -sf -m 5 "$1" > /dev/null 2>&1; do
        [ "${waited}" -ge "$2" ] && return 1
        sleep 1
        waited=$((waited + 1))
    done
}

start() {
    if running "${WEB_PID}" && running "${INFLUX_PID}"; then
        log "Scrutiny is already running with PID: $(cat ${WEB_PID})"

        return 0
    fi

    stop
    setup || return 1
    write_config
    set -- $(scrutiny_ids)
    cd "${DATA_PATH}/db" || return 1

    # InfluxDB first (Scrutiny sets it up the first time, and needs it to start): on the NAS itself only, without
    # reporting to InfluxData, and with a small cache (the NAS's memory is shared with everything else)
    log "starting InfluxDB on 127.0.0.1:${INFLUX_PORT} (log: ${INFLUX_LOG})"
    ( exec env HOME="${DATA_PATH}/influxdb" "${BIN}/scrutiny_runas" "$1" "$2" "${BIN}/influxd" \
        --bolt-path "${DATA_PATH}/influxdb/influxd.bolt" --engine-path "${DATA_PATH}/influxdb/engine" \
        --sqlite-path "${DATA_PATH}/influxdb/influxd.sqlite" --http-bind-address "127.0.0.1:${INFLUX_PORT}" \
        --reporting-disabled --log-level warn --storage-cache-max-memory-size 67108864 \
        --storage-cache-snapshot-memory-size 8388608 ) >> "${INFLUX_LOG}" 2>&1 &
    echo $! > "${INFLUX_PID}"

    if ! wait_for "http://127.0.0.1:${INFLUX_PORT}/health" 120; then
        log "InfluxDB didn't start (see ${INFLUX_LOG})"
        stop

        return 1
    fi

    log "starting Scrutiny on 127.0.0.1:${PORT} (log: ${WEB_LOG})"
    ( exec env HOME="${DATA_PATH}/db" "${BIN}/scrutiny_runas" "$1" "$2" "${BIN}/scrutiny-web" start --config "${CONFIG}" ) \
        >> "${WEB_LOG}" 2>&1 &
    echo $! > "${WEB_PID}"
    log "Scrutiny started with PID: $(cat ${WEB_PID})"

    # The disks read once it's up (rather than only at the next hour), in the background
    sh "${APP_PATH}/scrutiny_ctl.sh" collect > /dev/null 2>&1 &
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
    stop_one "${WEB_PID}" Scrutiny
    stop_one "${INFLUX_PID}" InfluxDB
}

# Reads the disks' SMART data with the collector (as root) and sends it to Scrutiny. Each of the NAS's disks is read as a
# SATA disk (smartctl's scan lists them as SCSI ones, whose SMART data is less complete), and one that's asleep is left
# asleep: not read at all this time (-n standby). One run at a time. (SMARTCTL in the environment: another smartctl - the tests' stand-in.)
#
# Returns the collector's exit code
collect() {
    local disk code smartctl="${SMARTCTL:-${BIN}/smartctl}"

    if ! mkdir /var/run/scrutiny-collect 2>/dev/null; then
        log 'the disks are already being read'

        return 1
    fi

    # Scrutiny may still be starting
    if ! wait_for "http://127.0.0.1:${PORT}/api/health" 120; then
        log "Scrutiny isn't answering: the disks weren't read"
        rmdir /var/run/scrutiny-collect

        return 1
    fi

    {
        echo '# Written by the app before each run (see scrutiny_ctl.sh) - changes here are lost'
        echo 'version: 1'
        echo 'host:'
        echo "  id: '$(hostname)'"
        echo 'devices:'

        for disk in /sys/block/sd*; do
            [ -e "${disk}/device" ] || continue
            disk="$(basename "${disk}")"
            "${smartctl}" -n standby -i "/dev/${disk}" > /dev/null 2>&1

            # Asleep (smartctl's exit code has bit 2 set: -n standby left it alone) - or not there: left out this time
            if [ $(($? & 2)) != 0 ]; then
                printf '  - device: /dev/%s\n    ignore: true\n' "${disk}"
            else
                printf "  - device: /dev/%s\n    type: 'sat'\n" "${disk}"
            fi
        done

        echo 'api:'
        echo "  endpoint: 'http://127.0.0.1:${PORT}'"
        echo 'commands:'
        echo "  metrics_smartctl_bin: '${smartctl}'"
        echo "  metrics_smart_args: '--xall --json -T permissive -n standby'"
        echo 'log:'
        echo "  file: '${COLLECTOR_LOG}'"
        echo '  level: INFO'
    } > "${COLLECTOR_CONFIG}.tmp"
    # (a NAS without any SATA disk: none to override)
    sed -i '/^devices:$/{N;s/^devices:\napi:/devices: []\napi:/}' "${COLLECTOR_CONFIG}.tmp"
    chmod 600 "${COLLECTOR_CONFIG}.tmp" && mv -f "${COLLECTOR_CONFIG}.tmp" "${COLLECTOR_CONFIG}"

    "${BIN}/scrutiny-collector-metrics" run --config "${COLLECTOR_CONFIG}" > /dev/null 2>&1
    code=$?
    date +%s > "${DATA_PATH}/last_collect"
    echo "${code}" >> "${DATA_PATH}/last_collect"
    rmdir /var/run/scrutiny-collect

    return "${code}"
}

# Keeps its logs under 1MB each (the previous part is kept as <log>.1).
#
# Prints nothing
rotate_logs() {
    local file

    for file in "${WEB_LOG}" "${INFLUX_LOG}" "${COLLECTOR_LOG}"; do
        if [ "$(wc -c < "${file}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            cp "${file}" "${file}.1" && : > "${file}"
            chmod 600 "${file}.1"
        fi
    done
}

# The Nginx app finds Scrutiny by its folder and serves it at https://scrutiny.<its domain>: rewrite its sites.
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
    collect) collect ;;
    new-password) new_password ;;
    daily) rotate_logs ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|collect|new-password|daily|nginx" >&2

        exit 1
        ;;
esac
