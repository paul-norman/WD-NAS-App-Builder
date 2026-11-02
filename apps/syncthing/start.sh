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

PID_FILE="/var/run/${APP_NAME}.pid"
SYNCTHING_LOG="${APP_PATH}/${APP_NAME}.log"

if is_running "${PID_FILE}"; then
    log "Syncthing is already running with PID: $(cat ${PID_FILE})"

    exit 0
fi

# Syncthing runs as root, so files it creates would otherwise be read-only for the NAS's users over SMB (the shares
# themselves are world-writable too)
umask 000

# Updates come with new versions of the app (with a NAS alert when one is released), so Syncthing mustn't update itself
log "starting Syncthing (output: ${SYNCTHING_LOG})"
STNODEFAULTFOLDER=1 HOME="${APP_PERSISTENT_DATA_PATH}" "${APP_PATH}/binaries/syncthing" serve \
    --home="${APP_PERSISTENT_DATA_PATH}" \
    --gui-address='0.0.0.0:8384' \
    --no-browser \
    --no-upgrade \
    --log-file="${SYNCTHING_LOG}" \
    --log-max-size=1048576 \
    --log-max-old-files=2 > /dev/null 2>&1 &
echo $! > ${PID_FILE}

log "Syncthing started with PID: $(cat ${PID_FILE})"
