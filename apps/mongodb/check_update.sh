#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks MongoDB's own list of releases for a newer one in the installed
# version's line (e.g. 8.0.x - a new major version needs its data upgraded step by step, so it's an app of its own) and
# shows it as a NAS alert (once per release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_mongodb/last_update_alert"
FEED='https://downloads.mongodb.org/full.json'

# Without the app's own packaging revision, e.g. 8.0.34-1
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
LINE="$(echo "${INSTALLED}" | cut -d . -f 1-2)"

if command -v curl > /dev/null; then
    RESPONSE="$(curl -sf --max-time 30 "${FEED}")"
else
    RESPONSE="$(wget -qO- "${FEED}")"
fi

# Its releases ("version": "8.0.34"), the newest stable one of the same line (no -rc versions)
LATEST="$(echo "${RESPONSE}" | sed -n 's/.*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | grep "^${LINE}\." \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)"

[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
    /usr/sbin/alert_test -a 1501 -p "<br><br><b>MongoDB ${LATEST}</b> (installed: ${INSTALLED})" -f
    echo "${LATEST}" > "${LAST_FILE}"
    echo "Alert shown: MongoDB ${LATEST} is available (installed: ${INSTALLED})"
else
    echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
