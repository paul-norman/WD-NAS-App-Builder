#!/bin/sh

# Called when app is disabled
    # -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH

# Called upon app removal
    # -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
    # -> 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# -----------------------------------------------------------------------------
# Stops the app from running
#  - /opt stays mounted (Entware's commands may be in use), clean.sh unmounts it
# -----------------------------------------------------------------------------

if [ -x /opt/etc/init.d/rc.unslung ]; then
    log 'stopping Entware services'
    /opt/etc/init.d/rc.unslung stop >> ${LOG} 2>&1
fi
