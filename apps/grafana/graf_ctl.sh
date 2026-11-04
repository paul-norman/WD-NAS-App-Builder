#!/bin/sh
# Runs Grafana as its own user, with its data in the persistent path (Nas_Prog/_grafana - kept across reinstalls):
#   graf_ctl.sh setup          - create its user, folders, settings and first admin password (where missing)
#   graf_ctl.sh start          - write its configuration, then start it (on port 3000: the whole network, or only the NAS
#                                itself for the Nginx app)
#   graf_ctl.sh stop           - stop Grafana
#   graf_ctl.sh restart        - stop, then start
#   graf_ctl.sh reset-password - set the admin account's password to the one given on standard input
#   graf_ctl.sh backup         - back up its database (safely, while it runs)
#   graf_ctl.sh daily          - the daily job: a backup, and keeping the log small
#   graf_ctl.sh nginx          - add / update Grafana's site in the Nginx app (and reload it)
#   graf_ctl.sh dashboards [--without <app>]
#                              - gather other apps' dashboards again (after one is installed or removed - --without leaves
#                                out an app being removed); Grafana picks the change up by itself within a minute
#
# Its configuration (grafana.ini) and provisioning (the Prometheus app and the logs app's Loki as data sources, and the
# dashboards - its own, and those other apps ship in Nas_Prog/<app>/dashboards) are written by the app at every start

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_grafana"
BIN="${APP_PATH}/binaries"
HOME_PATH="${BIN}/grafana"
GRAF_DATA="${DATA_PATH}/data"
CONFIG="${DATA_PATH}/grafana.ini"
PROVISIONING="${DATA_PATH}/provisioning"
APP_DASHBOARDS="${DATA_PATH}/app-dashboards"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
GRAF_LOG="${DATA_PATH}/grafana.log"
PID_FILE=/var/run/grafana.pid
PORT=3000
# Its own user and group (created if missing): the IDs used when creating them
GRAF_ID=74
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') grafana/graf_ctl.sh $*" >> ${LOG}
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
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
graf_ids() {
    awk -F: '$1 == "grafana" { print $3 " " $4 }' /etc/passwd
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^grafana:' /etc/group || addgroup -g ${GRAF_ID} grafana
    grep -q '^grafana:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${GRAF_ID} -G grafana grafana

    if [ -z "$(graf_ids)" ]; then
        log "Could not create the grafana user (are ID ${GRAF_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(graf_ids)

    # Its own data belongs to its user; the configuration, settings and password to root
    # All of Grafana's provisioning folders, even unused ones: it logs an error at every start for any that's missing
    mkdir -p "${GRAF_DATA}" "${PROVISIONING}/datasources" "${PROVISIONING}/dashboards" "${PROVISIONING}/alerting" \
        "${PROVISIONING}/plugins"
    chmod 711 "${DATA_PATH}"
    chown "$1:$2" "${GRAF_DATA}"
    chmod 700 "${GRAF_DATA}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LISTEN=all\nBACKUP_DIR=\nBACKUP_KEEP=7\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    # The admin password Grafana's database is created with (on its first start - changing it later is done in Grafana
    # or with the management page's reset). Grafana reads it from its own copy
    if [ ! -s "${PASSWORD_FILE}" ]; then
        ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}" )
        log "generated the first admin password: ${PASSWORD_FILE}"
    fi

    if [ ! -f "${GRAF_DATA}/grafana.db" ]; then
        cp "${PASSWORD_FILE}" "${GRAF_DATA}/.admin_password" && chown "$1:$2" "${GRAF_DATA}/.admin_password" \
            && chmod 600 "${GRAF_DATA}/.admin_password"
    fi

    touch "${GRAF_LOG}"
    chmod 600 "${GRAF_LOG}"
}

# grafana.ini and its provisioning
write_config() {
    host=0.0.0.0
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1
    # Its address in the Nginx app (for links Grafana makes, e.g. in alert notifications), if it has one
    root_url="$(php "${APP_PATH}/lib/graf.php" url "${APPS_PATH}" 2>/dev/null)"
    [ -n "${root_url}" ] || root_url='%(protocol)s://%(domain)s:%(http_port)s/'
    cat > "${CONFIG}.tmp" <<EOF
; Written by the Grafana app at every start: changes here are overwritten (Grafana's own settings are kept in its
; database, and changed in Grafana itself)
[paths]
data = ${GRAF_DATA}
logs = ${GRAF_DATA}/log
plugins = ${GRAF_DATA}/plugins
provisioning = ${PROVISIONING}
bundled_plugins = ${HOME_PATH}/data/plugins-bundled

[server]
http_addr = ${host}
http_port = ${PORT}
root_url = ${root_url}

[security]
admin_user = admin
admin_password = \$__file{${GRAF_DATA}/.admin_password}

; No telemetry, news feed or update checks (the app shows a NAS alert for new releases)
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
feedback_links_enabled = false

[news]
news_feed_enabled = false

; Nothing downloaded at start-up: plugins are installed from Grafana's catalogue when wanted
[plugins]
preinstall_disabled = true

[log]
mode = console
level = warn
EOF
    chmod 644 "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"

    # The Prometheus app as the default data source (when installed)
    if [ -d "${APPS_PATH}/prometheus" ]; then
        cat > "${PROVISIONING}/datasources/prometheus.yaml" <<EOF
# Written by the Grafana app: the Prometheus app (on the NAS itself)
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s
EOF
    else
        rm -f "${PROVISIONING}/datasources/prometheus.yaml"
    fi

    # The logs app's Loki as a data source, and its "NAS logs" dashboard (when installed)
    if [ -d "${APPS_PATH}/loki" ]; then
        cat > "${PROVISIONING}/datasources/loki.yaml" <<EOF
# Written by the Grafana app: the logs app's Loki (on the NAS itself)
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://127.0.0.1:3100
    editable: false
EOF
    else
        rm -f "${PROVISIONING}/datasources/loki.yaml"
    fi

    # (The logs app's dashboard had a provider of its own: it's one of the other apps' dashboards now)
    rm -f "${PROVISIONING}/dashboards/logs.yaml"
    sync_app_dashboards

    # The app's dashboards (read-only - copy one in Grafana to change it), in a "NAS" folder
    cat > "${PROVISIONING}/dashboards/nas.yaml" <<EOF
# Written by the Grafana app: its dashboards (Node Exporter Full, WD NAS)
apiVersion: 1
providers:
  - name: nas
    folder: NAS
    type: file
    disableDeletion: true
    allowUiUpdates: false
    options:
      path: ${BIN}/dashboards
  - name: nas-apps
    folder: NAS
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      path: ${APP_DASHBOARDS}
EOF
    chmod 644 "${PROVISIONING}"/*/*.yaml
}

# Copies the dashboards other apps ship (Nas_Prog/<app>/dashboards/*.json - e.g. the logs app's, the database
# exporters') into the folder Grafana reads them from (its "NAS" folder) - all but the app given: one being removed still
# has its files. Grafana notices the change by itself (every 30 seconds).
#
# $1 without An app to leave out, or nothing
#
# Prints nothing
sync_app_dashboards() {
    mkdir -p "${APP_DASHBOARDS}"
    chmod 755 "${APP_DASHBOARDS}"
    rm -f "${APP_DASHBOARDS:?}/"*.json

    for file in "${APPS_PATH}"/*/dashboards/*.json; do
        [ -f "${file}" ] || continue
        app="$(basename "$(dirname "$(dirname "${file}")")")"
        [ "${app}" = grafana ] || [ "${app}" = "${1:-}" ] && continue

        cp "${file}" "${APP_DASHBOARDS}/${app}-$(basename "${file}")"
        chmod 644 "${APP_DASHBOARDS}/${app}-$(basename "${file}")"
    done
}

start() {
    if running; then
        log "Grafana is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    write_config
    set -- $(graf_ids)
    log "starting Grafana on port ${PORT} (log: ${GRAF_LOG})"
    # Its log is appended to (so that it can be cut short while it runs)
    cd "${HOME_PATH}" || return 1
    ( exec env HOME="${GRAF_DATA}" "${BIN}/graf_runas" "$1" "$2" "${HOME_PATH}/bin/grafana" server \
        --homepath "${HOME_PATH}" --config "${CONFIG}" ) >> "${GRAF_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Grafana started with PID: $(cat ${PID_FILE})"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Grafana (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Grafana did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# With Grafana's own command, run as its user: the new password is read from standard input (never on a command line,
# which other processes can see) - and saved as the one the page shows
reset_password() {
    IFS= read -r password || [ -n "${password}" ] || { echo 'No password given' >&2; return 1; }
    set -- $(graf_ids)
    cd "${HOME_PATH}" || return 1

    if printf '%s\n' "${password}" | env HOME="${GRAF_DATA}" "${BIN}/graf_runas" "$1" "$2" "${HOME_PATH}/bin/grafana" cli \
        --homepath "${HOME_PATH}" --config "${CONFIG}" admin reset-admin-password --password-from-stdin 2>&1; then
        ( umask 077; printf '%s' "${password}" > "${PASSWORD_FILE}" )

        return 0
    fi

    return 1
}

backup() {
    dir="$(setting BACKUP_DIR "${DATA_PATH}/backups")"
    keep="$(setting BACKUP_KEEP 7)"

    if [ ! -f "${GRAF_DATA}/grafana.db" ]; then
        log 'Nothing to back up yet (no database - start Grafana first)'

        return 1
    fi

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" && chmod 700 "${dir}" || { log "Could not create the backup folder: ${dir}"; return 1; }
    fi

    stamp="$(date '+%Y%m%d-%H%M%S')"
    work="${dir}/.grafana-${stamp}"
    file="${dir}/grafana-${stamp}.tar.gz"
    rm -rf "${work}"
    mkdir -m 700 "${work}" || return 1

    # SQLite's online backup: a consistent copy, even while Grafana writes to it. Its dashboards, users, data sources,
    # alerts and settings are all in it
    if ! "${BIN}/sqlite3" -init /dev/null "${GRAF_DATA}/grafana.db" ".backup '${work}/grafana.db'" \
        || [ "$("${BIN}/sqlite3" -init /dev/null "${work}/grafana.db" 'PRAGMA integrity_check;')" != ok ]; then
        log 'The database backup failed'
        rm -rf "${work}"

        return 1
    fi

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${work}" . ) || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -rf "${work}" "${file}.tmp"

        return 1
    fi

    rm -rf "${work}"
    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/grafana-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' | while read -r old; do
        rm -f "${old}"
    done
}

# Keeps Grafana's log under 1MB (the previous part is kept as grafana.log.1)
rotate_log() {
    if [ "$(wc -c < "${GRAF_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${GRAF_LOG}" "${GRAF_LOG}.1" && : > "${GRAF_LOG}"
        chmod 600 "${GRAF_LOG}.1"
    fi
}

# The Nginx app finds Grafana by its folder and serves it at https://grafana.<its domain>: rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    reset-password) reset_password ;;
    backup) backup ;;
    daily) backup; rotate_log ;;
    nginx) nginx_site ;;
    dashboards)
        without=''
        [ "${2:-}" = '--without' ] && without="${3:-}"
        sync_app_dashboards "${without}"
        ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|reset-password|backup|daily|nginx|dashboards [--without <app>]" >echo "Usage: $0 setup|start|stop|restart|reset-password|backup|daily|nginx" >&22

        exit 1
        ;;
esac
