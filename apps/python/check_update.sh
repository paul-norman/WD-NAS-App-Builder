#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new Python release on the installed version's line (e.g.
# 3.14.x - security and bug fixes), as built by python-build-standalone, and shows it as a NAS alert (once per release).
# Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_python/last_update_alert"
API='https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'

# Without the app's own packaging revision, e.g. 2.10.7-1
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
LINE="${INSTALLED%.*}"

if command -v curl > /dev/null; then
    RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
    RESPONSE="$(wget -qO- "${API}")"
fi

# Its assets are named e.g. cpython-3.14.8+20261020-x86_64-...
LATEST="$(echo "${RESPONSE}" | grep -o "cpython-${LINE}\.[0-9]*+" | sort -u -t. -k3,3n | tail -n 1 | sed 's/^cpython-//; s/+$//')"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
    /usr/sbin/alert_test -a 1501 -p "<br><br><b>Python ${LATEST}</b> (installed: ${INSTALLED})" -f
    echo "${LATEST}" > "${LAST_FILE}"
    echo "Alert shown: Python ${LATEST} is available (installed: ${INSTALLED})"
else
    echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
