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

# Add binaries to the PATH
log "linking ${APP_NAME} binaries"
ln -sf ${APP_PATH}/binaries/* /sbin

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

# Setup
log "running daemon setup"
"${APP_PATH}/daemon.sh" setup

sleep 1

# Start
log "running daemon start"
"${APP_PATH}/daemon.sh" start

sleep 3

# Install Portainer (if there is no existing Portainer container (running or not))
log "installing Portainer"
docker ps -a | grep portainer-ce
if [ $? = 1 ]; then
	docker volume create portainer_data
	
	docker run -d -p 9000:9000 -p 9443:9443 --name portainer --restart always \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v portainer_data:/data portainer/portainer-ce:2.21.5
fi