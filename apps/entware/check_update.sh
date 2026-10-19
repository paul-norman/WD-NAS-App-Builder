#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for Entware package updates and shows them as a NAS alert (once
# per change in the number of updates). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_entware/last_update_alert"
OPKG=/opt/bin/opkg

[ -x "${OPKG}" ] || exit 0
"${OPKG}" update > /dev/null 2>&1 || exit 0

COUNT="$("${OPKG}" list-upgradable 2>/dev/null | wc -l)"
LAST="$(cat "${LAST_FILE}" 2>/dev/null)"

if [ "${COUNT}" -gt 0 ] && [ "${COUNT}" != "${LAST}" ] && [ -x /usr/sbin/alert_test ]; then
	/usr/sbin/alert_test -a 1501 -p "<br><br><b>Entware: ${COUNT} package update(s)</b> - run: opkg upgrade" -f
	echo "Alert shown: ${COUNT} Entware package update(s)"
else
	echo "No alert: ${COUNT} update(s), last alert was for: ${LAST:-none}"
fi
echo "${COUNT}" > "${LAST_FILE}"
