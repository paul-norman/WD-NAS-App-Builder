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

log "linking redirect page from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# Setup a persistent data directory
if [ -d ${APP_PERSISTENT_DATA_PATH} ]; then
	log "found existing ${APP_NAME} data directory, reusing it"
else
	log "creating a new ${APP_NAME} data directory"
	mkdir -p "${APP_PERSISTENT_DATA_PATH}"
fi

# Create a minimal config file
if [ ! -f "${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf" ]; then
	log "creating config file: ${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf"
	echo "bind 0.0.0.0 -::1" > "${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf"
	echo "protected-mode no" >> "${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf"
	echo "port 6379" >> "${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf"
	echo "dir ${APP_PERSISTENT_DATA_PATH}" >> "${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf"
fi

# Link the config file
log "linking config file: /etc/${APP_NAME}/${APP_NAME}.conf"
mkdir -p /etc/${APP_NAME}
ln -sf ${APP_PERSISTENT_DATA_PATH}/${APP_NAME}.conf /etc/${APP_NAME}/${APP_NAME}.conf >> ${LOG} 2>&1

log "linking binary files ${APP_PATH}/binaries/* to: /usr/bin"
ln -sf ${APP_PATH}/binaries/* /usr/bin >> ${LOG} 2>&1

log "linking Redis replacements ${APP_PATH}/binaries/* to: /usr/bin"
ln -sf ${APP_PATH}/binaries/valkey-server /usr/bin/redis-server >> ${LOG} 2>&1
ln -sf ${APP_PATH}/binaries/valkey-cli /usr/bin/redis-cli >> ${LOG} 2>&1