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

# Remove the daily log check
CRONTAB='/var/spool/cron/crontabs/root'

if [ -f "${CRONTAB}" ] && grep -q "${APP_NAME}-daily" "${CRONTAB}"; then
    grep -v "${APP_NAME}-daily" "${CRONTAB}" > "${CRONTAB}.tmp"
    mv "${CRONTAB}.tmp" "${CRONTAB}"
fi

# Its scrape job and dashboard go from the Prometheus and Grafana apps (its files are only removed after this)
sh "${APP_PATH}/exporter_ctl.sh" monitoring --without >> ${LOG} 2>&1
