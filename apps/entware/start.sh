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

OPT_ROOT="${APP_PERSISTENT_DATA_PATH}/opt"
INCOMPATIBLE_FILE="${APP_PERSISTENT_DATA_PATH}/incompatible"

# Not set up on this NAS (Entware's programs can't run on it: see init.sh)
[ -f "${INCOMPATIBLE_FILE}" ] && exit 0

if ! grep -q ' /opt ' /proc/mounts; then
    log "mounting ${OPT_ROOT} on /opt"
    mount --bind "${OPT_ROOT}" /opt
fi

# Checked again now that it's mounted: its opkg is started, in case the kernel's page size couldn't be read - if it
# crashes, Entware is removed (it would silently break the NAS's commands)
if ! reason="$(sh "${APP_PATH}/compat.sh" check)"; then
    log "Entware can't run on this NAS: ${reason} - removing it"
    printf '%s\n' "${reason}" > "${INCOMPATIBLE_FILE}"
    sh "${APP_PATH}/compat.sh" remove "${OPT_ROOT}" >> ${LOG} 2>&1
    cron_remove "${APP_NAME}-update-check"

    exit 0
fi

# Start the services installed with Entware's packages
if [ -x /opt/etc/init.d/rc.unslung ]; then
    log 'starting Entware services'
    /opt/etc/init.d/rc.unslung start >> ${LOG} 2>&1
fi
