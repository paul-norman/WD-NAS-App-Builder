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

# ----------------------------------------------------------------------------
# Starts the app when enabled (e.g. on boot)
#  - When no index page is defined in apkg.rc, the enable button is greyed out
# ----------------------------------------------------------------------------

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------------
# Nothing runs in the background: the Store works when its page is used. While it's on, the dashboard's Apps page is the
# Store's (its own copy of WD's addons/app.php, bind-mounted over WD's read-only one - stop.sh puts WD's back)
# ----------------------------------------------------------------------------

WD_APPS_PAGE=/usr/local/modules/web/pages/addons/app.php
if [ ! -f "${WD_APPS_PAGE}" ]; then
	log "no ${WD_APPS_PAGE}: the NAS's Apps page is left as it is"
elif awk -v page="${WD_APPS_PAGE}" '$2 == page { found = 1 } END { exit !found }' /proc/mounts; then
	log "the Apps page is already the Store's"
elif mount --bind "${APP_PATH}/wd/app.php" "${WD_APPS_PAGE}"; then
	log "the Apps page is now the Store's"
else
	log "could not replace the Apps page"
fi
