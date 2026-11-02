#!/bin/sh
# Sets Pi-hole up on the NAS (with the Docker app installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/pihole/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_pihole, creates .env there from example.env (with a generated web
# password, shown once - only the first time: an existing .env is kept), checks that ports 53 and 8053 are free, starts
# Pi-hole, and adds its site to the Nginx app (https://pihole.<domain>), if installed. Running it again is safe (e.g.
# after changing .env).
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_pihole
APPS_PATH=/mnt/HD/HD_a2/Nas_Prog

# A setting from .env (without quotes around it).
#
# $1 name The setting
#
# Prints its value
setting() {
    sed -n "s/^$1=//p" "${PROJECT}/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'$/\\1/"
}

if ! docker compose version > /dev/null 2>&1; then
    echo "Docker (with docker compose) isn't available: install or start the Docker app first"

    exit 1
fi

mkdir -p "${PROJECT}"
chmod 700 "${PROJECT}"
cp "${RECIPE_PATH}/compose.yaml" "${PROJECT}/compose.yaml"

if [ ! -f "${PROJECT}/.env" ]; then
    # The web password: letters and digits, written straight into the root-only .env
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
    ( umask 077; sed -e "s/^WEB_PASSWORD=.*/WEB_PASSWORD=${password}/" -e "s#^TZ=.*#TZ=$(cat /etc/TZ 2>/dev/null || echo Europe/London)#" \
        "${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
    echo "Created ${PROJECT}/.env - Pi-hole's web password is: ${password}"
fi

chmod 600 "${PROJECT}/.env"
mkdir -p "$(setting CONFIG_LOCATION)"

cd "${PROJECT}"

# Ports 53 and 8053 must be free - unless it's this Pi-hole that has them (running it again)
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
    sh "${RECIPE_PATH}/hooks/pre_install.sh"
fi

echo 'Starting Pi-hole'
docker compose pull
docker compose up -d

# Its site in the Nginx app, if installed - as the Store does for recipe.json's web.nginx
if [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
    if php "${APPS_PATH}/nginx/lib/sites.php" add-app "${APPS_PATH}/_nginx" pihole http://127.0.0.1:8053 'Pi-hole'; then
        sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
        url="$(php "${APPS_PATH}/nginx/lib/sites.php" url "${APPS_PATH}/_nginx" pihole)" \
            && echo "Added Pi-hole's site to the Nginx app: ${url}admin/" \
            || echo "Added Pi-hole's site to the Nginx app (pihole.<domain>, once a domain is set on its page)"
    fi
fi

echo "Pi-hole is starting: http://<nas-ip>:8053/admin in a minute. Then set your router's DNS server to the NAS's address"
