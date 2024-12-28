#!/bin/sh

# Called when app is disabled
	# -> 1. $INSTALL_PATH/stop.sh

# Called upon app removal
	# -> 1. $INSTALL_PATH/stop.sh
	#	 2. $INSTALL_PATH/clean.sh
	#	 3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
	# -> 1. $INSTALL_PATH/stop.sh
	#	 2. $INSTALL_PATH/clean.sh
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# -----------------------------------------------------------------------------
# Stops the app from running
#  - When no index page is defined in apkg.rc, the disable button is greyed out
# -----------------------------------------------------------------------------

log "Running daemon shutdown"
"${APP_PATH}/daemon.sh" shutdown

sleep 1

log "Remaining mounts:"
log "$(cat /proc/self/mounts | grep docker)"