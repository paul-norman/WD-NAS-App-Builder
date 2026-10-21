#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new Forgejo release on the installed version's line (e.g. 15.x,
# a long term support release) and shows it as a NAS alert (once per release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_forgejo/last_update_alert"
API="https://codeberg.org/api/v1/repos/forgejo/forgejo/releases?limit=20"

INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r')"
MAJOR="${INSTALLED%%.*}"
if command -v curl > /dev/null; then
	RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
	RESPONSE="$(wget -qO- "${API}")"
fi
# (newest first)
LATEST="$(echo "${RESPONSE}" | grep -o "\"tag_name\":[[:space:]]*\"v${MAJOR}\.[0-9.]*\"" | head -n 1 | sed 's/.*"v\([^"]*\)"/\1/')"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
	/usr/sbin/alert_test -a 1501 -p "<br><br><b>Forgejo ${LATEST}</b> (installed: ${INSTALLED})" -f
	echo "${LATEST}" > "${LAST_FILE}"
	echo "Alert shown: Forgejo ${LATEST} is available (installed: ${INSTALLED})"
else
	echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
