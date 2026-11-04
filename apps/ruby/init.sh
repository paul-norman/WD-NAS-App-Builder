#!/bin/sh

# Called upon app installation
    #    1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    # -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    #    2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    # -> 6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# ----------------------------------------------------------------------
# Initialisation script: prepares app icon, index page and paths
#  - Use this to restore custom paths and settings on reinstall / reboot
# ----------------------------------------------------------------------

# Where gems are installed, and their commands (kept when the app is updated or removed - see its README)
GEMS_PATH="${APP_PERSISTENT_DATA_PATH}"

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Gems' commands start the ruby next to them (Ruby is relocatable): there's one there, the app's
mkdir -p "${GEMS_PATH}/bin"
ln -sf "${APP_PATH}/binaries/bin/ruby" "${GEMS_PATH}/bin/ruby"

# Ruby's commands (ruby, gem, bundle, irb, rake...), then those of the gems installed since (the NAS's /usr/bin is
# rebuilt at every boot) - never over a command that's already there and isn't the app's
log "linking Ruby's commands, and installed gems' commands, into: /usr/bin"

for command in "${APP_PATH}"/binaries/bin/* "${GEMS_PATH}"/bin/*; do
    [ -f "${command}" ] && [ "${command}" != "${GEMS_PATH}/bin/ruby" ] || continue
    link="/usr/bin/$(basename "${command}")"
    target="$(readlink "${link}" 2>/dev/null)"

    case "${target}" in
        "${APP_PATH}"/*|"${GEMS_PATH}"/*) ln -sf "${command}" "${link}" ;;
        *) [ -e "${link}" ] || [ -L "${link}" ] || ln -s "${command}" "${link}" ;;
    esac
done
