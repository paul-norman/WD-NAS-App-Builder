#!/bin/sh

# Called upon app removal
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    # -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    # -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# --------------------------------------------------------------------
# Cleanup script to revert the init.sh steps. Ensures a clean shutdown
# --------------------------------------------------------------------

# Remove the web path
log "removing web paths: ${APP_WEB_PATH} ${APP_MANAGE_PATH}"
rm -rf ${APP_WEB_PATH} ${APP_MANAGE_PATH}

# Remove the rclone command (only if it's still the app's)
if [ "$(readlink /usr/bin/rclone)" = "${APP_PATH}/rclone_cli.sh" ]; then
    log 'removing the rclone command: /usr/bin/rclone'
    rm -f /usr/bin/rclone
fi

# Remove the hourly jobs, the daily log check and the update check
cron_remove "${APP_NAME}-jobs" "${APP_NAME}-daily" "${APP_NAME}-update-check"
