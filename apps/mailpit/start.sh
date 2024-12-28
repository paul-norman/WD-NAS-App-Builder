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

# Link Mailpit to the path
log "linking Mailpit binary: ${APP_PATH}/binaries/mailpit to: /usr/bin/mailpit"
ln -sf ${APP_PATH}/binaries/mailpit /usr/bin/mailpit >> ${LOG} 2>&1

PID_FILE="/var/run/${APP_NAME}.pid"

mailpit --smtp 0.0.0.0:1026 --smtp-auth-allow-insecure --smtp-auth-accept-any & 
echo $! > ${PID_FILE}

log "Mailpit started with PID: $(cat ${PID_FILE})"