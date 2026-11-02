#!/bin/sh
# Runs Loki (stores the logs, as its own user) and Vector (reads the NAS's log files and sends them to Loki, as root -
# many of the logs are readable by root only), with their data in the persistent path (Nas_Prog/_loki - kept across
# reinstalls):
#   loki_ctl.sh setup    - create Loki's user, the folders and settings (where missing)
#   loki_ctl.sh start    - write both configurations, then start Loki and Vector (Loki on the NAS itself only)
#   loki_ctl.sh stop     - stop Vector and Loki
#   loki_ctl.sh restart  - stop, then start
#   loki_ctl.sh daily    - the daily job: keeping the two logs small
#
# What's collected: the NAS's own logs (/var/log), the apps' logs (Nas_Prog/_<app>/*.log, the Nginx app's logs, the app
# scripts' /tmp/debug_apkg) and, while Docker runs, its containers' output. Each line is labelled with host, source
# (system, app or docker) and app

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_loki"
BIN="${APP_PATH}/binaries"
LOKI_DATA="${DATA_PATH}/data"
VECTOR_DATA="${DATA_PATH}/vector"
LOKI_CONFIG="${DATA_PATH}/loki.yaml"
VECTOR_CONFIG="${DATA_PATH}/vector.yaml"
SETTINGS_FILE="${DATA_PATH}/settings"
LOKI_LOG="${DATA_PATH}/loki.log"
VECTOR_LOG="${DATA_PATH}/vector.log"
LOKI_PID=/var/run/loki.pid
VECTOR_PID=/var/run/loki-vector.pid
DOCKER_SOCKET=/var/run/docker.sock
# Loki's own user and group (created if missing): the IDs used when creating them
LOKI_ID=75
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') loki/loki_ctl.sh $*" >> ${LOG}
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

# Whether the app's process is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
loki_ids() {
    awk -F: '$1 == "loki" { print $3 " " $4 }' /etc/passwd
}

setup() {
    # Loki's own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^loki:' /etc/group || addgroup -g ${LOKI_ID} loki
    grep -q '^loki:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${LOKI_ID} -G loki loki

    if [ -z "$(loki_ids)" ]; then
        log "Could not create the loki user (are ID ${LOKI_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(loki_ids)

    # Loki's data belongs to its user; Vector's position in each file (and everything else) to root
    mkdir -p "${LOKI_DATA}" "${VECTOR_DATA}"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${LOKI_DATA}"
    chmod 700 "${LOKI_DATA}" "${VECTOR_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'RETENTION_DAYS=30\nSYSTEM_LOGS=1\nAPP_LOGS=1\nDOCKER_LOGS=1\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${LOKI_LOG}" "${VECTOR_LOG}"
    chmod 600 "${LOKI_LOG}" "${VECTOR_LOG}"
}

write_loki_config() {
    cat > "${LOKI_CONFIG}.tmp" <<EOF
# Written by the logs app at every start: changes here are overwritten. A single Loki, storing everything on the NAS
auth_enabled: false

server:
  http_listen_address: 127.0.0.1
  http_listen_port: 3100
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: ${LOKI_DATA}
  storage:
    filesystem:
      chunks_directory: ${LOKI_DATA}/chunks
      rules_directory: ${LOKI_DATA}/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: $(($(setting RETENTION_DAYS 30) * 24))h
  reject_old_samples: true
  reject_old_samples_max_age: 168h

# Deletes logs older than the retention period
compactor:
  working_directory: ${LOKI_DATA}/compactor
  retention_enabled: true
  delete_request_store: filesystem

pattern_ingester:
  enabled: false

analytics:
  reporting_enabled: false
EOF
    chmod 644 "${LOKI_CONFIG}.tmp" && mv -f "${LOKI_CONFIG}.tmp" "${LOKI_CONFIG}"
}

write_vector_config() {
    inputs=''
    {
        cat <<EOF
# Written by the logs app at every start: changes here are overwritten. Vector reads the logs, labels them and sends them
# to Loki
data_dir: ${VECTOR_DATA}

sources:
EOF
        # The NAS's own logs (rsyslog's, rotated hourly to .1 and .gz files, which aren't read again); WD's private and
        # analytics logs are left out (noisy, and not meant for people)
        if [ "$(setting SYSTEM_LOGS 1)" = 1 ]; then
            inputs="${inputs}, system_logs"
            cat <<EOF
  system_logs:
    type: file
    include: ['/var/log/*.log', '/var/log/samba/*']
    exclude: ['/var/log/*private*', '/var/log/analytic*', '/var/log/samba/*.old', '/var/log/samba/cores']
    read_from: beginning
    ignore_older_secs: 86400
EOF
        fi

        # The apps' logs (the logs app's own are left out, so that it never reads what it writes about itself)
        if [ "$(setting APP_LOGS 1)" = 1 ]; then
            inputs="${inputs}, app_logs"
            cat <<EOF
  app_logs:
    type: file
    include: ['${APPS_PATH}/_*/*.log', '${APPS_PATH}/_nginx/logs/*.log', '/tmp/debug_apkg', '/tmp/node_exporter.log']
    exclude: ['${DATA_PATH}/*']
    read_from: beginning
    ignore_older_secs: 86400
EOF
        fi

        # Docker's containers, while Docker runs (only when its socket exists as Vector starts - restart the app after
        # installing Docker)
        if [ "$(setting DOCKER_LOGS 1)" = 1 ] && [ -S "${DOCKER_SOCKET}" ]; then
            inputs="${inputs}, docker_logs"
            cat <<EOF
  docker_logs:
    type: docker_logs
    docker_host: unix://${DOCKER_SOCKET}
EOF
        fi

        cat <<'EOF'

transforms:
  labelled:
    type: remap
    inputs: [__INPUTS__]
    source: |
      if .source_type == "docker_logs" {
        .source = "docker"
        .app = .container_name
      } else {
        file = string!(.file)
        app, err = parse_regex(file, r'/Nas_Prog/_(?P<name>[^/]+)/')
        if err == null {
          .source = "app"
          .app = app.name
        } else if starts_with(file, "/var/log/") {
          .source = "system"
          .app = replace(replace(file, "/var/log/", ""), r'\.log$', "")
        } else {
          .source = "app"
          .app = replace(replace(file, r'^.*/', ""), r'\.log$', "")
          if .app == "debug_apkg" { .app = "app-scripts" }
        }
      }

sinks:
  loki:
    type: loki
    inputs: [labelled]
    endpoint: http://127.0.0.1:3100
    encoding:
      codec: text
    labels:
      host: '{{ host }}'
      source: '{{ source }}'
      app: '{{ app }}'
    out_of_order_action: accept
    healthcheck:
      enabled: false
EOF
    } > "${VECTOR_CONFIG}.tmp"
    # The transform's inputs: the sources turned on
    sed -i "s/\[__INPUTS__\]/[${inputs#, }]/" "${VECTOR_CONFIG}.tmp"
    chmod 600 "${VECTOR_CONFIG}.tmp" && mv -f "${VECTOR_CONFIG}.tmp" "${VECTOR_CONFIG}"
    [ -n "${inputs}" ]
}

start() {
    setup || return 1

    if ! running "${LOKI_PID}"; then
        write_loki_config
        set -- $(loki_ids)
        log "starting Loki on 127.0.0.1:3100 (log: ${LOKI_LOG})"
        # Its log is appended to (so that it can be cut short while it runs)
        cd "${LOKI_DATA}" || return 1
        ( exec "${BIN}/loki_runas" "$1" "$2" "${BIN}/loki" -config.file="${LOKI_CONFIG}" ) >> "${LOKI_LOG}" 2>&1 &
        echo $! > "${LOKI_PID}"
    fi

    if ! running "${VECTOR_PID}"; then
        if ! write_vector_config; then
            log "Every log source is turned off: Vector isn't started"

            return 0
        fi

        log "starting Vector (log: ${VECTOR_LOG})"
        cd "${VECTOR_DATA}" || return 1
        ( exec env VECTOR_LOG=warn "${BIN}/vector" --config "${VECTOR_CONFIG}" ) >> "${VECTOR_LOG}" 2>&1 &
        echo $! > "${VECTOR_PID}"
    fi

    log "Loki (PID $(cat ${LOKI_PID} 2>/dev/null)) and Vector (PID $(cat ${VECTOR_PID} 2>/dev/null)) started"
}

# Stops one of them: $1 is its PID file, $2 its name
stop_one() {
    if running "$1"; then
        pid="$(cat "$1")"
        log "stopping $2 (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 30 ]; then
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
    # Vector first: it sends what it has read before stopping
    stop_one "${VECTOR_PID}" Vector
    stop_one "${LOKI_PID}" Loki
}

# Keeps the two logs under 1MB each (the previous part is kept as .1)
rotate_logs() {
    for file in "${LOKI_LOG}" "${VECTOR_LOG}"; do
        if [ "$(wc -c < "${file}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            cp "${file}" "${file}.1" && : > "${file}"
            chmod 600 "${file}.1"
        fi
    done
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    daily) rotate_logs ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|daily" >&2

        exit 1
        ;;
esac
