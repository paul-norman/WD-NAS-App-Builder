#!/bin/sh

# Called upon app removal
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    # -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/remove.sh $INSTALL_PATH

# Called upon app reinstallation
    #    1. $INSTALL_PATH/stop.sh $INSTALL_PATH
    # -> 2. $INSTALL_PATH/clean.sh $INSTALL_PATH
    #    3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
    #    4. $INSTALL_PATH/remove.sh $INSTALL_PATH
    #    5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
    #    6. $INSTALL_PATH/init.sh $INSTALL_PATH
    #    7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1"

# --------------------------------------------------------------------
# Cleanup script to revert the init.sh steps. Ensures a clean shutdown
# --------------------------------------------------------------------

# Remove its commands (only the links to the app's own k3s)
for command in k3s kubectl crictl; do
    if [ "$(readlink "/sbin/${command}")" = "${APP_PATH}/binaries/k3s" ]; then
        rm -f "/sbin/${command}"
    fi
done

# Its configuration and kubeconfig (in RAM), the links to the node's password and the pods' logs (both kept with the
# cluster), and the kubelet's device plugin socket (always in /var/lib/kubelet)
rm -rf /etc/rancher/k3s
[ -L /etc/rancher/node ] && rm -f /etc/rancher/node
rmdir /etc/rancher 2>/dev/null
[ -L /var/log/pods ] && rm -f /var/log/pods
rm -rf /var/lib/kubelet/device-plugins
rmdir /var/lib/kubelet 2>/dev/null

# Unload the app's own kernel modules where nothing uses them any more (k3s has stopped by now; the Docker app may still
# use overlay, which then stays)
log "unloading the app's kernel modules"
rmmod iptable_mangle ipt_REJECT nf_reject_ipv4 xt_mark xt_statistic xt_multiport xt_comment 2>/dev/null
rmmod overlay 2>/dev/null

# Remove the web path
log "removing web paths: ${APP_WEB_PATH} ${APP_MANAGE_PATH}"
rm -rf ${APP_WEB_PATH} ${APP_MANAGE_PATH}

# Remove the daily log check and the update check
CRONTAB='/var/spool/cron/crontabs/root'

if [ -f "${CRONTAB}" ] && grep -q "${APP_NAME}-" "${CRONTAB}"; then
    grep -v "${APP_NAME}-daily\|${APP_NAME}-update-check" "${CRONTAB}" > "${CRONTAB}.tmp"
    mv "${CRONTAB}.tmp" "${CRONTAB}"
fi
