#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new phpBB release in the installed version's line (e.g. 3.3.x
# - a new major version needs its own app) and shows it as a NAS alert (once per release). Can also be run by hand.
# phpBB publishes no GitHub releases: its release tags (release-<version>) are read instead

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_phpbb/last_update_alert"
API='https://api.github.com/repos/phpbb/phpbb/tags?per_page=100'

# Without the app's own packaging revision, e.g. 3.3.19-1
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
LINE="$(echo "${INSTALLED}" | cut -d . -f 1-2)"

if command -v curl > /dev/null; then
    RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
    RESPONSE="$(wget -qO- "${API}")"
fi

# Stable releases of the same line only (not -RC, -a or -b ones), the newest last
LATEST="$(echo "${RESPONSE}" | sed -n 's/.*"name":[[:space:]]*"release-\([0-9][0-9.]*\)".*/\1/p' \
    | grep "^${LINE}\." | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)"

[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
    /usr/sbin/alert_test -a 1501 -p "<br><br><b>phpBB ${LATEST}</b> (installed: ${INSTALLED})" -f
    echo "${LATEST}" > "${LAST_FILE}"
    echo "Alert shown: phpBB ${LATEST} is available (installed: ${INSTALLED})"
else
    echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
