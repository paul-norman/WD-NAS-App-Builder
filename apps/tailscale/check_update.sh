#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new Tailscale release and shows it as a NAS alert (once per
# release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_tailscale/last_update_alert"
API="https://api.github.com/repos/tailscale/tailscale/releases/latest"

INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r')"
if command -v curl > /dev/null; then
	RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
	RESPONSE="$(wget -qO- "${API}")"
fi
LATEST="$(echo "${RESPONSE}" | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
	/usr/sbin/alert_test -a 1501 -p "<br><br><b>Tailscale ${LATEST}</b> (installed: ${INSTALLED})" -f
	echo "${LATEST}" > "${LAST_FILE}"
	echo "Alert shown: Tailscale ${LATEST} is available (installed: ${INSTALLED})"
else
	echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
