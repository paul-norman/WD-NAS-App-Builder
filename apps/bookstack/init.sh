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

# Its own user, folders and settings (kept across reinstalls, in Nas_Prog/_bookstack - its database and administrator
# are set up on its first start)
sh "${APP_PATH}/bookstack_ctl.sh" setup >> ${LOG} 2>&1

# A backup and keeping its logs small every day, and a weekly check for a new BookStack release (shown as a NAS alert).
# OS5 regenerates root's crontab on every boot, so they're added here (init.sh runs on every boot) - via a temporary
# file, as BusyBox crond only notices replaced files
CRONTAB='/var/spool/cron/crontabs/root'

if [ -f "${CRONTAB}" ] && ! grep -q "${APP_NAME}-daily" "${CRONTAB}"; then
    cp "${CRONTAB}" "${CRONTAB}.tmp" \
        && echo "35 3 * * * ${APP_PATH}/bookstack_ctl.sh daily # ${APP_NAME}-daily" >> "${CRONTAB}.tmp" \
        && echo "15 6 * * 1 ${APP_PATH}/check_update.sh # ${APP_NAME}-update-check" >> "${CRONTAB}.tmp" \
        && mv "${CRONTAB}.tmp" "${CRONTAB}" \
        && log "added the daily backup and log check, and the weekly update check to: ${CRONTAB}"
fi

# Its site in the Nginx app (https://bookstack.<the Nginx app's domain>, from its nginx.json)
sh "${APP_PATH}/bookstack_ctl.sh" nginx >> ${LOG} 2>&1
