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
#  - When no index page is defined in apkg.rc, the disable button is greyed out
# -----------------------------------------------------------------------------

# Only remove our own symlink
if [ "$(readlink /usr/bin/nano)" = "${APP_PATH}/binaries/nano" ]; then
    log 'Removing binary symlink from: /usr/bin/nano'
    rm -f /usr/bin/nano
fi

# Restoring old nano (if present) /usr/local/modules/usr/bin/nano
if [ ! -e /usr/bin/nano ] && { [ -e /usr/bin/nano.OLD ] || [ -L /usr/bin/nano.OLD ]; }; then
    log 'restoring system nano from: /usr/bin/nano.OLD'
    mv /usr/bin/nano.OLD /usr/bin/nano
fi
