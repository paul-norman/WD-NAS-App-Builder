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

PASSWORD_FILE="${APP_PERSISTENT_DATA_PATH}/gui_password"

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Syncthing's configuration, keys and database live in the persistent path (kept across reinstalls)
mkdir -p "${APP_PERSISTENT_DATA_PATH}"

# First run: generate the configuration with a random GUI password. Syncthing runs as root and its GUI listens on the
# network, so it must never be left without one (the password is readable by root only)
if [ ! -f "${APP_PERSISTENT_DATA_PATH}/config.xml" ]; then
    log "generating Syncthing's configuration, with a GUI password in: ${PASSWORD_FILE}"
    tr -dc A-Za-z0-9 </dev/urandom | head -c 20 > "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
    STNODEFAULTFOLDER=1 "${APP_PATH}/binaries/syncthing" generate --home="${APP_PERSISTENT_DATA_PATH}" \
        --gui-user=admin --gui-password="$(cat "${PASSWORD_FILE}")" >> ${LOG} 2>&1
    # Privacy: decline anonymous usage reporting (rather than Syncthing asking when its GUI is first opened)
    sed -i 's|<urAccepted>0</urAccepted>|<urAccepted>-1</urAccepted>|' "${APP_PERSISTENT_DATA_PATH}/config.xml"
    chmod 600 "${APP_PERSISTENT_DATA_PATH}/config.xml"
fi

# Weekly check for a new Syncthing release, shown as a NAS alert. OS5 regenerates root's crontab on every boot, so it
# is added here (init.sh runs on every boot) - via a temporary file, as BusyBox crond only notices replaced files
CRONTAB='/var/spool/cron/crontabs/root'
CRON_TAG="${APP_NAME}-update-check"

if [ -f "${CRONTAB}" ] && ! grep -q "${CRON_TAG}" "${CRONTAB}"; then
    cp "${CRONTAB}" "${CRONTAB}.tmp" \
        && echo "0 6 * * 1 ${APP_PATH}/check_update.sh # ${CRON_TAG}" >> "${CRONTAB}.tmp" \
        && mv "${CRONTAB}.tmp" "${CRONTAB}" \
        && log "added the weekly update check to: ${CRONTAB}"
fi
