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

# Link the core features into the global path
log "linking core binaries to path: ${APP_PATH}/binaries/bin/* to: /usr/bin"
ln -sf ${APP_PATH}/binaries/bin/node /usr/bin/node >> ${LOG} 2>&1
ln -sf ${APP_PATH}/binaries/bin/npm /usr/bin/npm >> ${LOG} 2>&1
ln -sf ${APP_PATH}/binaries/bin/npx /usr/bin/npx >> ${LOG} 2>&1
ln -sf ${APP_PATH}/binaries/bin/corepack /usr/bin/corepack >> ${LOG} 2>&1

# Create a test server as a check
cd ${APP_PATH}/web/test_server
log "installing the test server files in $(pwd)"
npm install