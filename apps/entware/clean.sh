#!/bin/sh

# Called upon app removal
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	# -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	# -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	#	 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# --------------------------------------------------------------------
# Cleanup script to revert the init.sh steps. Ensures a clean shutdown
# --------------------------------------------------------------------

# Remove the web path
log "removing web path: ${APP_WEB_PATH}"
rm -rf ${APP_WEB_PATH}

# Remove the update check, the PATH lines and the reboot wrapper
CRONTAB="/var/spool/cron/crontabs/root"
if [ -f "${CRONTAB}" ] && grep -q "${APP_NAME}-update-check" "${CRONTAB}"; then
	grep -v "${APP_NAME}-update-check" "${CRONTAB}" > "${CRONTAB}.tmp" && mv "${CRONTAB}.tmp" "${CRONTAB}"
fi
sed -i "/# added by the entware app/d" /etc/profile 2>/dev/null
if [ "$(readlink /opt/sbin/reboot)" = "${APP_PATH}/bin/reboot" ]; then
	rm -f /opt/sbin/reboot
fi

# Give root a plain (non-persistent) home folder again
if [ -L /home/root ]; then
	rm -f /home/root
	mkdir -p /home/root
fi

# Unmount /opt (lazily if something is still using it, rather than killing it)
log "unmounting /opt"
umount /opt 2>/dev/null || umount -l /opt 2>/dev/null
