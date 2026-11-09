#!/bin/sh

# Called upon app installation
    #    1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    # -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    # -> 6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# ----------------------------------------------------------------------
# Initialisation script: prepares app icon, index page and paths
#  - Use this to restore custom paths and settings on reinstall / reboot
# ----------------------------------------------------------------------

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p "${APP_WEB_PATH}"

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf "${APP_PATH}"/web/* "${APP_WEB_PATH}" >> "${LOG}" 2>&1

# The Store's page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login: it installs software as
# root
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p "${APP_MANAGE_PATH}"
ln -sf "${APP_PATH}"/manage/* "${APP_PATH}"/web/* "${APP_MANAGE_PATH}" >> "${LOG}" 2>&1

# Its repositories, cached catalogues and jobs are kept in the persistent path (root only: job files hold wizard
# answers)
mkdir -p "${APP_PERSISTENT_DATA_PATH}/jobs"
chmod 700 "${APP_PERSISTENT_DATA_PATH}"

# A daily check of the repositories for new versions at 04:25 (the page also checks when it opens, if it's been over an
# hour), then the automatic updates at 04:30 (of the apps and recipes ticked "Update automatically" - nothing runs if
# none are)
cron_add '25 4 * * *' "php ${APP_PATH}/lib/refresh.php > /dev/null 2>&1" "${APP_NAME}-refresh"
cron_add '30 4 * * *' "php ${APP_PATH}/lib/auto_update.php > /dev/null 2>&1" "${APP_NAME}-auto-update"
