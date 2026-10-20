#!/bin/sh

# Called when app is enabled
	# -> 1. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	# -> 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	# -> 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------------
# Starts Node Exporter, and the script that adds WD's storage metrics
#  - Its files are kept in RAM (/tmp), so nothing is written to the disks every scrape, and sleeping disks stay asleep
# ----------------------------------------------------------------------------

PID_FILE="/var/run/${APP_NAME}.pid"
WD_PID_FILE="/var/run/${APP_NAME}-wd.pid"
SETTINGS_FILE="${APP_PERSISTENT_DATA_PATH}/settings"
WEB_CONFIG="${APP_PERSISTENT_DATA_PATH}/web-config.yml"
TEXTFILE_DIR="/tmp/node_exporter-textfile"
NE_LOG="/tmp/node_exporter.log"

# WD's storage metrics, refreshed every 30 seconds
if ! is_running "${WD_PID_FILE}"; then
	log "starting the WD storage metrics script (writes: ${TEXTFILE_DIR}/wd.prom)"
	CAP_LOG="${NE_LOG}" /bin/sh "${APP_PATH}/wd_metrics.sh" "${TEXTFILE_DIR}" 30 > /dev/null 2>&1 &
	echo $! > "${WD_PID_FILE}"
fi

if is_running "${PID_FILE}"; then
	log "Node Exporter is already running with PID: $(cat ${PID_FILE})"
	exit 0
fi

# The port, and whether scrapes need a password (only with a web config the management page has written)
PORT="$(sed -n 's/^PORT=\([0-9]*\)$/\1/p' "${SETTINGS_FILE}" 2>/dev/null)"
[ -n "${PORT}" ] || PORT=9100
WEB_CONFIG_FLAG=""
if grep -q '^AUTH=1$' "${SETTINGS_FILE}" 2>/dev/null && [ -f "${WEB_CONFIG}" ]; then
	WEB_CONFIG_FLAG="--web.config.file=${WEB_CONFIG}"
fi

# Its log is in RAM too: warnings only, kept under 1MB by the WD metrics script (appended to, so it can be cut short)
log "starting Node Exporter on port ${PORT} (output: ${NE_LOG})"
mkdir -p "${TEXTFILE_DIR}"
: > "${NE_LOG}"
"${APP_PATH}/binaries/node_exporter" \
	--web.listen-address=":${PORT}" \
	${WEB_CONFIG_FLAG} \
	--collector.textfile.directory="${TEXTFILE_DIR}" \
	--log.level=warn >> "${NE_LOG}" 2>&1 &
echo $! > ${PID_FILE}

log "Node Exporter started with PID: $(cat ${PID_FILE})"
