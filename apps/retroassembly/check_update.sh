#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new RetroAssembly version (its git tags: it publishes few
# GitHub releases) and shows it as a NAS alert (once per version). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_retroassembly/last_update_alert"
API='https://api.github.com/repos/arianrhodsandlot/retroassembly/tags?per_page=100'

# Without the app's own packaging revision, e.g. 2.10.7-1
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"

if command -v curl > /dev/null; then
    RESPONSE="$(curl -sf --max-time 20 "${API}")"
else
    RESPONSE="$(wget -qO- "${API}")"
fi

# (the newest of its version tags, e.g. v7.261011.1345)
LATEST="$(echo "${RESPONSE}" | sed -n 's/.*"name":[[:space:]]*"v\([0-9][0-9.]*\)".*/\1/p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
    /usr/sbin/alert_test -a 1501 -p "<br><br><b>RetroAssembly ${LATEST}</b> (installed: ${INSTALLED})" -f
    echo "${LATEST}" > "${LAST_FILE}"
    echo "Alert shown: RetroAssembly ${LATEST} is available (installed: ${INSTALLED})"
else
    echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
