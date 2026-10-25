#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new wireguard-go release and shows it as a NAS alert (once per
# release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_wireguard/last_update_alert"
# (wireguard-go's releases are tags on its own git server: the newest is listed first)
TAGS="https://git.zx2c4.com/wireguard-go/refs/tags"

# (without the app's own packaging revision, e.g. 2.10.7-1)
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
if command -v curl > /dev/null; then
	RESPONSE="$(curl -sf --max-time 20 "${TAGS}")"
else
	RESPONSE="$(wget -qO- "${TAGS}")"
fi
LATEST="$(echo "${RESPONSE}" | grep -o 'tag/?h=[0-9][0-9.]*' | head -n 1 | sed 's/tag\/?h=//')"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
	/usr/sbin/alert_test -a 1501 -p "<br><br><b>WireGuard (wireguard-go) ${LATEST}</b> (installed: ${INSTALLED})" -f
	echo "${LATEST}" > "${LAST_FILE}"
	echo "Alert shown: wireguard-go ${LATEST} is available (installed: ${INSTALLED})"
else
	echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
