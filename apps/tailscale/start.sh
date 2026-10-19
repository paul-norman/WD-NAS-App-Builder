#!/bin/sh

# Called when app is enabled
	# -> 1. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	# -> 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	# -> 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# ----------------------------------------------------------------------------
# Starts the app when enabled (e.g. on boot)
#  - When no index page is defined in apkg.rc, the enable button is greyed out
# ----------------------------------------------------------------------------

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

PID_FILE="/var/run/${APP_NAME}.pid"
TAILSCALE_LOG="${APP_PATH}/${APP_NAME}.log"
SOCKET="/var/run/tailscale/tailscaled.sock"

if is_running "${PID_FILE}"; then
	log "Tailscale is already running with PID: $(cat ${PID_FILE})"
	exit 0
fi

# The daemon remembers its login and settings, and reconnects by itself (log in once with: tailscale up). The socket is
# where the tailscale command expects it
mkdir -p "$(dirname "${SOCKET}")"
log "starting tailscaled (output: ${TAILSCALE_LOG})"
"${APP_PATH}/binaries/tailscaled" \
	--statedir="${APP_PERSISTENT_DATA_PATH}" \
	--socket="${SOCKET}" \
	--port=41641 > "${TAILSCALE_LOG}" 2>&1 &
echo $! > ${PID_FILE}

log "tailscaled started with PID: $(cat ${PID_FILE})"
