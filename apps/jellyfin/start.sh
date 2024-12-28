#!/bin/sh

# Called when app is enabled
	# -> 1. $INSTALL_PATH/start.sh

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	# -> 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh
	#	 2. $INSTALL_PATH/clean.sh
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

# Set max stack size
ulimit -s 3000

JELLYFIN_PATH="/opt/${APP_NAME}"
JELLYFIN_BIN_PATH="${JELLYFIN_PATH}/usr/lib/jellyfin/bin"
#FFMPEG_BIN_PATH="/opt/${APP_NAME}/ffmpeg/usr/lib/jellyfin-ffmpeg"
FFMPEG_BIN_PATH="/opt/${APP_NAME}/ffmpeg/bin"
PID_FILE="/var/run/${APP_NAME}.pid"

log "starting app..."
log "COMMAND: ${JELLYFIN_BIN_PATH}/jellyfin -d ${JELLYFIN_PATH}/data -C ${JELLYFIN_PATH}/cache -c ${JELLYFIN_PATH}/config -l ${JELLYFIN_PATH}/log --ffmpeg ${FFMPEG_BIN_PATH}/ffmpeg"

${JELLYFIN_BIN_PATH}/jellyfin \
 -d ${JELLYFIN_PATH}/data \
 -C ${JELLYFIN_PATH}/cache \
 -c ${JELLYFIN_PATH}/config \
 -l ${JELLYFIN_PATH}/log \
 --ffmpeg ${FFMPEG_BIN_PATH}/ffmpeg & 
echo $! > ${PID_FILE}

log "...app started with PID: $(cat ${PID_FILE})"
