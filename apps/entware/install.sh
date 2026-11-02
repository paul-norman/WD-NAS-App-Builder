#!/bin/sh

# Called upon app installation
    # -> 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    2. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    # -> 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1" "$2"

# ----------------------------------------------------------------------------------
# Install script: moves the required files to a permanent home
#  - Entware itself (/opt) and root's home folder live in the persistent path, so they survive reinstalls
# ----------------------------------------------------------------------------------

OPT_ROOT="${APP_PERSISTENT_DATA_PATH}/opt"
HOME_ROOT="${APP_PERSISTENT_DATA_PATH}/home"
mkdir -p "${APP_PERSISTENT_DATA_PATH}"

# Take over an existing Entware from the older WDCommunity app (same package name), whose upgrade scripts rename its
# Entware root to entware.bak and leave root's home folder inside its app folder - so move both before replacing it
if [ ! -d "${HOME_ROOT}" ] && [ -d "${APP_PATH}/home" ]; then
    log "Moving root's home folder from the previous Entware app: ${APP_PATH}/home to: ${HOME_ROOT}"
    mv "${APP_PATH}/home" "${HOME_ROOT}"
fi

if [ ! -d "${OPT_ROOT}" ]; then
    for old in "$(dirname "${APPS_PATH}")/entware.bak" "$(dirname "${APPS_PATH}")/entware" /shares/Volume_1/entware.bak /shares/Volume_1/entware; do
        if [ -x "${old}/bin/opkg" ]; then
            log "Moving the existing Entware from: ${old} to: ${OPT_ROOT}"
            mv "${old}" "${OPT_ROOT}"
            break
        fi
    done
fi

# Replace any previous app folder (its data has been moved to the persistent path above). The name check guards
# against ever removing the whole apps folder
if [ "${APP_NAME}" = 'entware' ]; then
    rm -rf "${APP_PATH}"
fi

log "Moving files from: ${APP_UPLOAD_PATH} to: ${APPS_PATH}"
mv -f "${APP_UPLOAD_PATH}" "${APPS_PATH}"

# A fresh install: run Entware's installer (bundled at build time) in the new root
if [ ! -x "${OPT_ROOT}/bin/opkg" ]; then
    mkdir -p "${OPT_ROOT}"

    if ! grep -q ' /opt ' /proc/mounts; then
        mount --bind "${OPT_ROOT}" /opt
    fi

    log "Installing Entware into: ${OPT_ROOT}"
    sh "${APP_PATH}/installer/generic.sh" >> ${LOG} 2>&1
fi

# Entware's installer bootstraps over plain HTTP (no CA certificates yet), and older installs taken over above may still
# use it, so switch package downloads to HTTPS (if that fails, the management page can retry it)
if grep -q 'http://bin.entware.net' "${OPT_ROOT}/etc/opkg.conf" 2>/dev/null; then
    if ! grep -q ' /opt ' /proc/mounts; then
        mount --bind "${OPT_ROOT}" /opt
    fi

    log 'Switching Entware package downloads to HTTPS'
    sh "${APP_PATH}/use_https.sh" >> ${LOG} 2>&1
fi
