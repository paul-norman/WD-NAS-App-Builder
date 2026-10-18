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

log "Running daemon setup"
"${APP_PATH}/daemon.sh" setup

# Starting is a no-op when Docker is already running, and only returns once it is ready for commands
log "Running daemon start"
if ! "${APP_PATH}/daemon.sh" start; then
	log "Docker failed to start, see: ${APP_PERSISTENT_DATA_PATH}/docker.log"
	exit 1
fi

# Install Portainer (if there is no existing Portainer container (running or not))
if [ -z "$(/sbin/docker ps -a -q --filter "name=^portainer$")" ]; then
	log "installing Portainer"
	/sbin/docker volume create portainer_data >> ${LOG} 2>&1
	/sbin/docker run -d -p 9000:9000 -p 9443:9443 --name portainer --restart always \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v portainer_data:/data portainer/portainer-ce:2.45.2 >> ${LOG} 2>&1
fi

log "$(/sbin/docker ps)"
