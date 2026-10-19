#!/bin/sh

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh $INSTALL_PATH
	#	 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------
# Initialisation script: prepares app icon, index page and paths
#  - Use this to restore custom paths and settings on reinstall / reboot
# ----------------------------------------------------------------------

OPT_ROOT="${APP_PERSISTENT_DATA_PATH}/opt"
HOME_ROOT="${APP_PERSISTENT_DATA_PATH}/home"
PROFILE_MARK="# added by the entware app"

# Create folder for the webpage
log "creating web path: ${APP_WEB_PATH}"
mkdir -p ${APP_WEB_PATH}

log "linking web files from: ${APP_PATH}/web/* to: ${APP_WEB_PATH}"
ln -sf ${APP_PATH}/web/* ${APP_WEB_PATH} >> ${LOG} 2>&1

# The management page (shown in the NAS dashboard) only goes where nasAdmin requires a NAS login
log "linking management page from: ${APP_PATH}/manage/* to: ${APP_MANAGE_PATH}"
mkdir -p ${APP_MANAGE_PATH}
ln -sf ${APP_PATH}/manage/* ${APP_PATH}/web/* ${APP_MANAGE_PATH} >> ${LOG} 2>&1

# Mount Entware's root on /opt
mkdir -p "${OPT_ROOT}" "${HOME_ROOT}"
if ! grep -q " /opt " /proc/mounts; then
	log "mounting ${OPT_ROOT} on /opt"
	mount --bind "${OPT_ROOT}" /opt
fi

# The mount hides WD's own /opt/wd (used by WD's services), so link it back in
if [ -d /usr/local/modules/opt/wd ] && [ ! -e /opt/wd ]; then
	log "linking WD's /opt/wd"
	ln -s /usr/local/modules/opt/wd /opt/wd
fi

# /opt/sbin comes before the system's own folders in the PATH, so provide a reboot that stops Entware cleanly first
mkdir -p /opt/sbin
ln -sf "${APP_PATH}/bin/reboot" /opt/sbin/reboot

# A persistent home folder for root (SSH keys, shell history...), which is otherwise reset on every boot
if [ "$(readlink /home/root)" != "${HOME_ROOT}" ]; then
	log "linking root's home folder: /home/root -> ${HOME_ROOT}"
	if [ -d /home/root ] && [ ! -L /home/root ]; then
		cp -a /home/root/. "${HOME_ROOT}/" 2>/dev/null
		rm -rf /home/root
	fi
	rm -f /home/root
	ln -s "${HOME_ROOT}" /home/root
fi

# Put Entware's commands first in the PATH (marked so that clean.sh can remove the lines again)
if ! grep -q "${PROFILE_MARK}" /etc/profile 2>/dev/null; then
	log "adding Entware to the PATH in: /etc/profile"
	echo "export PATH=/opt/bin:/opt/sbin:\${PATH} ${PROFILE_MARK}" >> /etc/profile
	echo "alias ll='ls -l' ${PROFILE_MARK}" >> /etc/profile
fi

# Weekly check for Entware package updates, shown as a NAS alert. OS5 regenerates root's crontab on every boot, so it
# is added here (init.sh runs on every boot) - via a temporary file, as BusyBox crond only notices replaced files
CRONTAB="/var/spool/cron/crontabs/root"
CRON_TAG="${APP_NAME}-update-check"
if [ -f "${CRONTAB}" ] && ! grep -q "${CRON_TAG}" "${CRONTAB}"; then
	cp "${CRONTAB}" "${CRONTAB}.tmp" \
		&& echo "0 6 * * 1 ${APP_PATH}/check_update.sh # ${CRON_TAG}" >> "${CRONTAB}.tmp" \
		&& mv "${CRONTAB}.tmp" "${CRONTAB}" \
		&& log "added the weekly update check to: ${CRONTAB}"
fi
