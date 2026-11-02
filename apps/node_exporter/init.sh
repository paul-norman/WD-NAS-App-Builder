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

SETTINGS_FILE="${APP_PERSISTENT_DATA_PATH}/settings"

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Settings (kept across reinstalls): the port, and whether scrapes need a password (set from the management page)
mkdir -p "${APP_PERSISTENT_DATA_PATH}"
chmod 700 "${APP_PERSISTENT_DATA_PATH}"

if [ ! -f "${SETTINGS_FILE}" ]; then
    log "creating the default settings: ${SETTINGS_FILE}"
    printf 'PORT=9100\nAUTH=0\n' > "${SETTINGS_FILE}"
fi

# Weekly check for a new Node Exporter release, shown as a NAS alert. OS5 regenerates root's crontab on every boot, so
# it is added here (init.sh runs on every boot) - via a temporary file, as BusyBox crond only notices replaced files
CRONTAB='/var/spool/cron/crontabs/root'
CRON_TAG="${APP_NAME}-update-check"

if [ -f "${CRONTAB}" ] && ! grep -q "${CRON_TAG}" "${CRONTAB}"; then
    cp "${CRONTAB}" "${CRONTAB}.tmp" \
        && echo "0 6 * * 1 ${APP_PATH}/check_update.sh # ${CRON_TAG}" >> "${CRONTAB}.tmp" \
        && mv "${CRONTAB}.tmp" "${CRONTAB}" \
        && log "added the weekly update check to: ${CRONTAB}"
fi
