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

# ----------------------------------------------------------------------------
# Starts the app when enabled (e.g. on boot)
#  - When no index page is defined in apkg.rc, the enable button is greyed out
# ----------------------------------------------------------------------------

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

PID_FILE="/var/run/${APP_NAME}.pid"
JELLYFIN_LOG="${APP_PATH}/${APP_NAME}.log"

if is_running "${PID_FILE}"; then
	log "Jellyfin is already running with PID: $(cat ${PID_FILE})"
	exit 0
fi

# Large libraries need many open files, and temporary files belong on disk rather than in the NAS's RAM
ulimit -n 65536 2>/dev/null
export TMPDIR="${APP_PERSISTENT_DATA_PATH}/tmp"

# A fresh install: start with hardware transcoding set up for this NAS's GPU (Jellyfin fills in the other settings)
ENCODING_FILE="${APP_PERSISTENT_DATA_PATH}/config/encoding.xml"
if [ ! -f "${ENCODING_FILE}" ]; then
	log "setting up transcoding for this NAS's GPU in: ${ENCODING_FILE}"
	sh "${APP_PATH}/transcoding.sh" apply "${ENCODING_FILE}" >> ${LOG} 2>&1
fi

# bin/ffmpeg is a wrapper that runs jellyfin-ffmpeg with the newer libva / libdrm it needs (the NAS's are too old)
log "starting Jellyfin (output: ${JELLYFIN_LOG})"
"${APP_PATH}/binaries/jellyfin/jellyfin" \
	--datadir "${APP_PERSISTENT_DATA_PATH}/data" \
	--cachedir "${APP_PERSISTENT_DATA_PATH}/cache" \
	--configdir "${APP_PERSISTENT_DATA_PATH}/config" \
	--logdir "${APP_PERSISTENT_DATA_PATH}/log" \
	--ffmpeg "${APP_PATH}/bin/ffmpeg" > "${JELLYFIN_LOG}" 2>&1 &
echo $! > ${PID_FILE}

log "Jellyfin started with PID: $(cat ${PID_FILE})"
