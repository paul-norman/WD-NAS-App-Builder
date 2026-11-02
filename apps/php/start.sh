#!/bin/sh

# Called when app is enabled
    # -> 1. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app installation
    #    1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    2. $INSTALL_PATH/init.sh $INSTALL_PATH
    # -> 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    # -> 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# ----------------------------------------------------------------------------
# Starts the app when enabled (e.g. on boot)
#  - When no index page is defined in apkg.rc, the enable button is greyed out
# ----------------------------------------------------------------------------

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# PHP 8.5 becomes the NAS's own PHP (php-fpm switches over gracefully, so that the NAS's web interface carries on). If
# it can't be switched, WD's PHP 7.4 carries on
log 'switching the NAS to PHP 8.5'
sh "${APP_PATH}/php_swap.sh" swap > /dev/null 2>> ${LOG}

# The Nginx app's sites run their own php-fpm, started from this app's: if it's running (e.g. this app was just
# updated), it's restarted onto this app's version - a running program keeps using the file it was started from
NGINX_PHP_PID="${APPS_PATH}/_nginx/logs/php-fpm.pid"

if [ -f "${APPS_PATH}/nginx/nginx_ctl.sh" ] && [ -f "${NGINX_PHP_PID}" ] && kill -0 "$(cat "${NGINX_PHP_PID}")" 2>/dev/null; then
    log "restarting the Nginx app's PHP for its sites"
    sh "${APPS_PATH}/nginx/nginx_ctl.sh" php-restart >> ${LOG} 2>&1
fi
