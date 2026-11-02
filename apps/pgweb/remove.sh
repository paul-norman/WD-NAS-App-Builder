#!/bin/sh

# Called upon app removal
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    # -> 3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    # -> 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# ----------------------------------------------------------------------------
# Removes all the app completely.
#  - pgweb's settings, password and saved queries are kept in the persistent path (Nas_Prog/_pgweb)
# ----------------------------------------------------------------------------

log "Removing all files from: ${APP_PATH}"
rm -rf "${APP_PATH}"

# Without the app's folder (and its nginx.json), the Nginx app no longer serves pgweb: rewrite its sites
if [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
    php "${APPS_PATH}/nginx/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
fi
