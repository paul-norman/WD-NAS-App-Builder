#!/bin/sh

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh
	#	 2. $INSTALL_PATH/clean.sh
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------
# Initialisation script: prepares app icon, index page and paths
#  - Use this to restore custom paths and settings on reinstall / reboot
# ----------------------------------------------------------------------

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# Create a folder that will persist
if [ ! -d "${APP_PERSISTENT_DATA_PATH}" ]; then
	log "creating persistent storage directory: ${APP_PERSISTENT_DATA_PATH}"
	mkdir -p ${APP_PERSISTENT_DATA_PATH}
fi

# Create folders that are required by Jellyfin
if [ ! -d "${APP_PERSISTENT_DATA_PATH}/data" ]; then
	log "creating persistent data directory: ${APP_PERSISTENT_DATA_PATH}/data"
	mkdir -p ${APP_PERSISTENT_DATA_PATH}/data
fi

if [ ! -d "${APP_PERSISTENT_DATA_PATH}/cache" ]; then
	log "creating persistent cache directory: ${APP_PERSISTENT_DATA_PATH}/cache"
	mkdir -p ${APP_PERSISTENT_DATA_PATH}/cache
fi

if [ ! -d "${APP_PERSISTENT_DATA_PATH}/config" ]; then
	log "creating persistent config directory: ${APP_PERSISTENT_DATA_PATH}/config"
	mkdir -p ${APP_PERSISTENT_DATA_PATH}/config
fi

if [ ! -d "${APP_PERSISTENT_DATA_PATH}/log" ]; then
	log "creating persistent log directory: ${APP_PERSISTENT_DATA_PATH}/log"
	mkdir -p ${APP_PERSISTENT_DATA_PATH}/log
fi

# Link the folders to the app
log "linking data directories from: ${APP_PERSISTENT_DATA_PATH}/* to: ${APP_PATH}/binaries"
ln -sf ${APP_PERSISTENT_DATA_PATH}/* ${APP_PATH}/binaries >> ${LOG} 2>&1

# Create Jellyfin-Web folder
JELLYFIN_BIN_PATH="${APP_PATH}/binaries/usr/lib/jellyfin/bin"
if [ ! -d "${JELLYFIN_BIN_PATH}/jellyfin-web" ]; then
	log "creating Jellyfin-Web directory: ${JELLYFIN_BIN_PATH}/jellyfin-web"
	mkdir -p ${JELLYFIN_BIN_PATH}/jellyfin-web
	
	# Link the web client to the bin dir
	log "linking jellyfin-web directories from: ${APP_PATH}/binaries/jellyfin-web/usr/share/jellyfin/web/* to: ${JELLYFIN_BIN_PATH}/jellyfin-web"
	ln -sf ${APP_PATH}/binaries/jellyfin-web/usr/share/jellyfin/web/* ${JELLYFIN_BIN_PATH}/jellyfin-web >> ${LOG} 2>&1
fi

# Link the app `binaries` directory to their recommended location `/opt/jellyfin`
log "linking binaries from: ${APP_PATH}/binaries to: /opt/${APP_NAME}"
mkdir -p "/opt/${APP_NAME}"
ln -sf ${APP_PATH}/binaries /opt/${APP_NAME}/jellyfin >> ${LOG} 2>&1
