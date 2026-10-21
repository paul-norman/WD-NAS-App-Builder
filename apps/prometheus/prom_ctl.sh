#!/bin/sh
# Runs Prometheus as its own user, with its data in the persistent path (Nas_Prog/_prometheus - kept across reinstalls):
#   prom_ctl.sh setup    - create its user, folders and settings (where missing)
#   prom_ctl.sh start    - write its configuration, then start it (on port 9090: the NAS itself only, or the whole network)
#   prom_ctl.sh stop     - stop Prometheus
#   prom_ctl.sh restart  - stop, then start
#   prom_ctl.sh reload   - rewrite its configuration (e.g. after the Node Exporter app's settings changed) and reload it
#
# Its configuration (prometheus.yml) is written by the app: it scrapes itself and the Node Exporter app (following its
# port and password). Other scrape jobs go in scrape.d/*.yml, and alerting / recording rules in rules.d/*.yml

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_prometheus"
BIN="${APP_PATH}/binaries"
TSDB="${DATA_PATH}/data"
CONFIG="${DATA_PATH}/prometheus.yml"
SETTINGS_FILE="${DATA_PATH}/settings"
NE_PASSWORD="${DATA_PATH}/node_exporter.password"
PROM_LOG="${DATA_PATH}/prometheus.log"
PID_FILE=/var/run/prometheus.pid
PORT=9090
# Its own user and group (created if missing): the IDs used when creating them
PROM_ID=73
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') prometheus/prom_ctl.sh $*" >> ${LOG}
	echo "$*"
}

# A setting from a settings file (default: the app's own, written by the management page), or the default given
setting() {
	value="$(sed -n "s/^$1=//p" "${3:-${SETTINGS_FILE}}" 2>/dev/null | head -n 1)"
	echo "${value:-$2}"
}

running() {
	[ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
prom_ids() {
	awk -F: '$1 == "prometheus" { print $3 " " $4 }' /etc/passwd
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^prometheus:' /etc/group || addgroup -g ${PROM_ID} prometheus
	grep -q '^prometheus:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${PROM_ID} -G prometheus prometheus
	if [ -z "$(prom_ids)" ]; then
		log "Could not create the prometheus user (are ID ${PROM_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(prom_ids)

	# Its database belongs to its user; the configuration, settings and the user's own files to root
	mkdir -p "${TSDB}" "${DATA_PATH}/scrape.d" "${DATA_PATH}/rules.d"
	chmod 755 "${DATA_PATH}"
	chown "$1:$2" "${TSDB}"
	chmod 700 "${TSDB}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'LISTEN=local\nRETENTION_DAYS=30\n' > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	if [ ! -f "${DATA_PATH}/scrape.d/README.txt" ]; then
		cat > "${DATA_PATH}/scrape.d/README.txt" <<'EOF'
Your own scrape jobs: one or more *.yml files here, each holding scrape_configs entries, e.g. (my-router.yml):

scrape_configs:
  - job_name: router
    static_configs:
      - targets: ['192.168.1.1:9100']

Then press "Reload" on the app's page (Prometheus keeps its current configuration if a file has an error - the page
shows it). Alerting and recording rules go in ../rules.d/*.yml, in Prometheus' rule file format.
EOF
	fi
	touch "${PROM_LOG}"
	chmod 600 "${PROM_LOG}"
}

# prometheus.yml: Prometheus itself, the Node Exporter app (if installed), and the user's own scrape jobs and rules
write_config() {
	set -- $(prom_ids)
	ne_settings="${APPS_PATH}/_node_exporter/settings"
	ne_job=""
	if [ -d "${APPS_PATH}/node_exporter" ]; then
		ne_port="$(setting PORT 9100 "${ne_settings}")"
		# The NAS's name as the instance, rather than 127.0.0.1:<port> (dashboards show it)
		ne_job="
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:${ne_port}']
        labels:
          instance: '$(hostname)'"
		# With a password (the Node Exporter app's own file is root's: Prometheus gets a copy)
		if [ "$(setting AUTH 0 "${ne_settings}")" = 1 ] && [ -s "${APPS_PATH}/_node_exporter/password" ]; then
			cp "${APPS_PATH}/_node_exporter/password" "${NE_PASSWORD}.tmp" && chown "$1:$2" "${NE_PASSWORD}.tmp" \
				&& chmod 600 "${NE_PASSWORD}.tmp" && mv -f "${NE_PASSWORD}.tmp" "${NE_PASSWORD}"
			ne_job="${ne_job}
    basic_auth:
      username: prometheus
      password_file: '${NE_PASSWORD}'"
		else
			rm -f "${NE_PASSWORD}"
		fi
	fi
	cat > "${CONFIG}.tmp" <<EOF
# Written by the Prometheus app at every start (and by its page's Reload): changes here are overwritten. Add your own
# scrape jobs in scrape.d/*.yml, and rules in rules.d/*.yml
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_config_files:
  - '${DATA_PATH}/scrape.d/*.yml'

rule_files:
  - '${DATA_PATH}/rules.d/*.yml'

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PORT}']
        labels:
          instance: '$(hostname)'${ne_job}
EOF
	chmod 644 "${CONFIG}.tmp" && mv -f "${CONFIG}.tmp" "${CONFIG}"
}

start() {
	if running; then
		log "Prometheus is already running with PID: $(cat ${PID_FILE})"
		return 0
	fi
	setup || return 1
	write_config
	set -- $(prom_ids)
	host=127.0.0.1
	[ "$(setting LISTEN local)" = all ] && host=0.0.0.0
	log "starting Prometheus on ${host}:${PORT} (log: ${PROM_LOG})"
	# Its log is appended to (so that it can be cut short while it runs); no --web.enable-lifecycle, so that nothing on the
	# network can stop or reload it (reloads are a signal from the app)
	cd "${TSDB}" || return 1
	( exec "${BIN}/prom_runas" "$1" "$2" "${BIN}/prometheus" \
		--config.file="${CONFIG}" \
		--storage.tsdb.path="${TSDB}" \
		--storage.tsdb.retention.time="$(setting RETENTION_DAYS 30)d" \
		--web.listen-address="${host}:${PORT}" \
		--log.level=warn ) >> "${PROM_LOG}" 2>&1 &
	echo $! > "${PID_FILE}"
	log "Prometheus started with PID: $(cat ${PID_FILE})"
}

stop() {
	if running; then
		pid="$(cat "${PID_FILE}")"
		log "stopping Prometheus (PID ${pid})"
		kill "${pid}"
		# (it writes out its recent data first)
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 60 ]; then
				log "Prometheus did not stop within 60 seconds, killing it"
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "${PID_FILE}"
}

reload() {
	write_config
	if running; then
		kill -HUP "$(cat "${PID_FILE}")"
		log "Prometheus reloaded its configuration"
	fi
}

# Keeps Prometheus' log under 1MB (the previous part is kept as prometheus.log.1)
rotate_log() {
	if [ "$(wc -c < "${PROM_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		cp "${PROM_LOG}" "${PROM_LOG}.1" && : > "${PROM_LOG}"
		chmod 600 "${PROM_LOG}.1"
	fi
}

case "$1" in
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	restart) stop; start ;;
	reload) reload ;;
	daily) rotate_log ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|reload|daily" >&2
		exit 1
		;;
esac
