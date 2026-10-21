#!/bin/sh

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
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

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Add binaries to the PATH
log "linking ${APP_NAME} binaries"
ln -sf ${APP_PATH}/binaries/* /sbin

# Compose is also a Docker CLI plugin, so "docker compose" works as well as "docker-compose" (/usr is in RAM, so this is
# redone on every boot)
log "linking docker-compose as a Docker CLI plugin"
mkdir -p /usr/libexec/docker/cli-plugins
ln -sf ${APP_PATH}/binaries/docker-compose /usr/libexec/docker/cli-plugins/docker-compose

# Setup a persistent data directory
if [ -d ${APP_PERSISTENT_DATA_PATH} ]; then
	if [ -d ${APP_PERSISTENT_DATA_PATH}/devicemapper ]; then
		log "Found old ${APP_NAME} devicemapper. Backing up and creating a fresh ${APP_NAME} data directory"
		mv "${APP_PERSISTENT_DATA_PATH}" "${APP_PERSISTENT_DATA_PATH}.bak"
		mkdir -p "${APP_PERSISTENT_DATA_PATH}"
	else
		log "Found existing ${APP_NAME} data directory, reusing it"
	fi
else
	log "Creating a new ${APP_NAME} data directory"
	mkdir -p "${APP_PERSISTENT_DATA_PATH}"
fi

# The daemon itself (and Portainer) is started by start.sh, which always runs straight after this script
