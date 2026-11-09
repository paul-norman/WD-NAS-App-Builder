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
# Stops the app: when the NAS is shutting down, runs the tasks set for that first; then takes its tasks out of cron
# (tasks already running carry on)
# -----------------------------------------------------------------------------

log 'stopping app...'
sh "${APP_PATH}/tasks_ctl.sh" stop >> "${LOG}" 2>&1
