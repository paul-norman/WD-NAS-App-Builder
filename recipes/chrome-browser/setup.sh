#!/bin/sh
# Sets the Chrome Browser up on the NAS (with the Docker app installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/chrome-browser/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_chrome-browser, creates .env there from example.env (with
# the NAS's time zone - only the first time: an existing .env is kept), starts Chrome, and has the changedetection.io
# app use it (if it's installed). Running it again is safe (e.g. after changing .env).
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_chrome-browser

if ! docker compose version > /dev/null 2>&1; then
    echo "Docker (with docker compose) isn't available: install or start the Docker app first"

    exit 1
fi

mkdir -p "${PROJECT}"
chmod 700 "${PROJECT}"
cp "${RECIPE_PATH}/compose.yaml" "${PROJECT}/compose.yaml"

if [ ! -f "${PROJECT}/.env" ]; then
    # The NAS's time zone, as its PHP has it (as the Store finds it - else example.env's)
    zone="$(sed -n 's/^[[:space:]]*date\.timezone[[:space:]]*=[[:space:]]*"\{0,1\}\([A-Za-z0-9_+/-]*\).*/\1/p' \
        /etc/php/php.ini 2>/dev/null | head -n 1)"
    ( umask 077; sed -e "s#^TZ=.*#TZ=${zone:-Europe/London}#" "${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
    echo "Created ${PROJECT}/.env"
fi

chmod 600 "${PROJECT}/.env"
cd "${PROJECT}"

echo 'Starting Chrome'
docker compose pull
docker compose up -d

# Then the app uses it (as the Store's post_install hook has it)
set -a
. "${PROJECT}/.env"
set +a
sh "${RECIPE_PATH}/hooks/post_install.sh"
