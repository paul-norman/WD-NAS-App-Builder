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

PID_FILE="/var/run/${APP_NAME}.pid"

OVERCOMMIT_FILE="/var/run/${APP_NAME}_overcommit_memory"

# Allow time for ValKey to save its data to disk before it is killed
log 'stopping app...'
stop_process "${PID_FILE}" 30

# Restore the system memory overcommit setting
if [ -f "${OVERCOMMIT_FILE}" ]; then
    log "restoring vm.overcommit_memory to: $(cat ${OVERCOMMIT_FILE})"
    sysctl -w vm.overcommit_memory="$(cat ${OVERCOMMIT_FILE})" >> ${LOG} 2>&1
    rm -f "${OVERCOMMIT_FILE}"
fi
