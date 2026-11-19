#!/bin/sh
# After an install or an update (the Store's post_install and post_update hooks, also run by setup.sh): waits for Chrome
# to answer on its DevTools port (127.0.0.1:9222, up to 2 minutes), then has the changedetection.io app (if it's
# installed) use it - which restarts the app. Run in the recipe's folder (in Nas_Prog, next to the app's), with .env's
# variables in the environment.

APPS_PATH="$(dirname "${STORE_DATA:-$(pwd)}")"
APP_CTL="${APPS_PATH}/changedetection/changedetection_ctl.sh"
waited=0

while [ ${waited} -lt 120 ]; do
    curl -sf -m 3 http://127.0.0.1:9222/json/version > /dev/null 2>&1 && break
    sleep 3
    waited=$((waited + 3))
done

version="$(curl -sf -m 3 http://127.0.0.1:9222/json/version 2>/dev/null \
    | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')"

if [ -n "${version}" ]; then
    echo "Chrome is answering: ${version}"
else
    echo 'Chrome is not answering yet (see: docker logs chrome-browser)'
fi

if [ ! -f "${APP_CTL}" ]; then
    echo 'Programs on the NAS can drive it at http://127.0.0.1:9222'
    echo '(The changedetection.io app, if installed later: choose "Chrome on this NAS" on its page)'

    exit 0
fi

sh "${APP_CTL}" browser on > /dev/null 2>&1 \
    && echo 'changedetection.io now uses this browser (restarted)' \
    || echo 'changedetection.io could not be restarted with this browser - see its page'
