#!/bin/sh
# Before the recipe is removed (the Store's pre_uninstall hook): the changedetection.io app stops using this browser (if
# it does) - which restarts it - so that its watches fall back to plain requests rather than failing. Run in the
# recipe's folder (in Nas_Prog, next to the app's).

APPS_PATH="$(dirname "${STORE_DATA:-$(pwd)}")"
APP_CTL="${APPS_PATH}/changedetection/changedetection_ctl.sh"
SETTINGS="${APPS_PATH}/_changedetection/settings"

[ -f "${APP_CTL}" ] || exit 0

if grep -qx 'BROWSER_URL=http://127.0.0.1:9222' "${SETTINGS}" 2>/dev/null; then
    sh "${APP_CTL}" browser off > /dev/null 2>&1 \
        && echo 'changedetection.io no longer uses a browser (restarted)' \
        || echo 'changedetection.io could not be restarted without the browser - see its page'
fi

exit 0
