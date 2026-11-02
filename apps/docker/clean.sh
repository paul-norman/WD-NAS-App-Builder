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

# Remove binary symlinks
log 'removing binaries'
rm -f /sbin/containerd*
rm -f /sbin/ctr
rm -f /sbin/docker*
rm -f /sbin/runc
rm -f /usr/libexec/docker/cli-plugins/docker-compose
rmdir /usr/libexec/docker/cli-plugins /usr/libexec/docker 2>/dev/null

# Unload the app's own kernel modules (Docker has stopped by now)
log "unloading the app's kernel modules"
rmmod overlay iptable_raw 2>/dev/null

# Remove the web and management paths
log "removing web paths: ${APP_WEB_PATH} ${APP_MANAGE_PATH}"
rm -rf ${APP_WEB_PATH} ${APP_MANAGE_PATH}

# Remove mountpoint (needed?)
log 'removing: /var/lib/docker'
rm -rf /var/lib/docker
