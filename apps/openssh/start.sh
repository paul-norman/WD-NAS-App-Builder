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

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------------
# Makes the app's OpenSSH the NAS's sshd (see ssh_ctl.sh: a trial login first, WD's put back if it fails)
# ----------------------------------------------------------------------------

log "switching the NAS to OpenSSH ${APP_VERSION}"
sh "${APP_PATH}/ssh_ctl.sh" swap > /dev/null 2>> ${LOG}
