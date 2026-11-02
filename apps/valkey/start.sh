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
VALKEY_LOG="${APP_PATH}/${APP_NAME}.log"
OVERCOMMIT_FILE="/var/run/${APP_NAME}_overcommit_memory"

if is_running "${PID_FILE}"; then
    log "ValKey is already running with PID: $(cat ${PID_FILE})"

    exit 0
fi

# ValKey recommends memory overcommit, remember the system setting so that stop.sh can restore it
if [ ! -f "${OVERCOMMIT_FILE}" ]; then
    cat /proc/sys/vm/overcommit_memory > "${OVERCOMMIT_FILE}"
fi

sysctl -w vm.overcommit_memory=1 >> ${LOG} 2>&1

log "starting ValKey (output: ${VALKEY_LOG})"
"${APP_PATH}/binaries/valkey-server" "/etc/${APP_NAME}/${APP_NAME}.conf" > "${VALKEY_LOG}" 2>&1 &
echo $! > ${PID_FILE}

log "ValKey started with PID: $(cat ${PID_FILE})"
