#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new Icecast release and shows it as a NAS alert (once per
# release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_icecast/last_update_alert"
# Icecast's download page names its current source release
API='https://icecast.org/download/'

# Without the app's own packaging revision, e.g. 2.10.7-1
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"

if command -v curl > /dev/null; then
    RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
    RESPONSE="$(wget -qO- "${API}")"
fi
LATEST="$(echo "${RESPONSE}" | grep -o 'icecast-[0-9][0-9.]*[0-9]\.tar\.gz' | head -n 1 | sed 's/icecast-//; s/\.tar\.gz//')"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
    /usr/sbin/alert_test -a 1501 -p "<br><br><b>Icecast ${LATEST}</b> (installed: ${INSTALLED})" -f
    echo "${LATEST}" > "${LAST_FILE}"
    echo "Alert shown: Icecast ${LATEST} is available (installed: ${INSTALLED})"
else
    echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
