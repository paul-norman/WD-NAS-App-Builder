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

# Its own user, folders and web interface password (kept across reinstalls, in Nas_Prog/_rclone)
sh "${APP_PATH}/rclone_ctl.sh" setup >> ${LOG} 2>&1

# The rclone command, for SSH (with the app's config file: see rclone_cli.sh) - and the browser opener rclone looks for,
# which does nothing (see rclone_ctl.sh, start): both run as programs
chmod 755 "${APP_PATH}/rclone_cli.sh" "${APP_PATH}/nobrowser/xdg-open"
log "linking the rclone command: /usr/bin/rclone"
ln -sf "${APP_PATH}/rclone_cli.sh" /usr/bin/rclone >> ${LOG} 2>&1

# The page's jobs (hourly: those set for that hour run), keeping its log small every day, and a weekly check for a new
# rclone release (shown as a NAS alert). OS5 regenerates root's crontab on every boot, so they're added here (init.sh
# runs on every boot) - via a temporary file, as BusyBox crond only notices replaced files
CRONTAB='/var/spool/cron/crontabs/root'

if [ -f "${CRONTAB}" ] && ! grep -q "${APP_NAME}-daily" "${CRONTAB}"; then
    cp "${CRONTAB}" "${CRONTAB}.tmp" \
        && echo "0 * * * * ${APP_PATH}/rclone_ctl.sh due # ${APP_NAME}-jobs" >> "${CRONTAB}.tmp" \
        && echo "15 4 * * * ${APP_PATH}/rclone_ctl.sh daily # ${APP_NAME}-daily" >> "${CRONTAB}.tmp" \
        && echo "0 6 * * 1 ${APP_PATH}/check_update.sh # ${APP_NAME}-update-check" >> "${CRONTAB}.tmp" \
        && mv "${CRONTAB}.tmp" "${CRONTAB}" \
        && log "added the hourly jobs, the daily log check and the weekly update check to: ${CRONTAB}"
fi

# Its site in the Nginx app (https://rclone.<the Nginx app's domain>)
sh "${APP_PATH}/rclone_ctl.sh" nginx >> ${LOG} 2>&1
