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
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Its own user, folders and settings (kept across reinstalls, in Nas_Prog/_metube)
sh "${APP_PATH}/metube_ctl.sh" setup >> ${LOG} 2>&1

# Every day: keeping its logs small; and the newest yt-dlp (YouTube changes often), unless turned off on its page
cron_add '15 3 * * *' "${APP_PATH}/metube_ctl.sh daily" "${APP_NAME}-daily"
cron_add '0 4 * * *' "${APP_PATH}/metube_ctl.sh ytdlp" "${APP_NAME}-ytdlp"

# Its site in the Nginx app (https://videos.<the Nginx app's domain>, from its nginx.json)
sh "${APP_PATH}/metube_ctl.sh" nginx >> ${LOG} 2>&1
