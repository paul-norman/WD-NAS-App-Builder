#!/bin/sh

# Called when app is disabled
	# -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH

# Called upon app removal
	# -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
	# -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# -----------------------------------------------------------------------------
# A job that's running (e.g. the Store updating itself) is left to finish. The dashboard's Apps page goes back to WD's
# -----------------------------------------------------------------------------

WD_APPS_PAGE=/usr/local/modules/web/pages/addons/app.php
while awk -v page="${WD_APPS_PAGE}" '$2 == page { found = 1 } END { exit !found }' /proc/mounts; do
	log "putting the NAS's own Apps page back"
	umount "${WD_APPS_PAGE}" 2>/dev/null || umount -l "${WD_APPS_PAGE}" || break
done
