#!/bin/sh
# Sets Frigate up on the NAS (with the Docker app installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/frigate/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_frigate, creates .env there from example.env (with a generated admin
# password, shown once - only the first time: an existing .env is kept), checks that ports 8971 and 8554 are free,
# writes Frigate's first settings, starts Frigate, applies the object detection setting (DETECTOR) and adds its site to
# the Nginx app (https://cameras.<domain>), if installed. Running it again is safe (e.g. after changing .env).
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_frigate
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
ACTION=change

if [ ! -f "${PROJECT}/.env" ]; then
    # The admin password: letters and digits, written straight into the root-only .env
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
    ( umask 077; sed -e "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${password}/" \
        -e "s#^TZ=.*#TZ=$(cat /etc/TZ 2>/dev/null || echo Europe/London)#" \
        "${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
    echo "Created ${PROJECT}/.env - Frigate's admin password (user: admin) is: ${password}"
    ACTION=install
fi

chmod 600 "${PROJECT}/.env"

# The recordings go in a folder on a share: the share itself must exist (created in the NAS dashboard, so that it's
# shared)
recordings="$(setting RECORDINGS)"
share="$(echo "${recordings}" | cut -d/ -f1-5)"

if [ ! -d "${share}" ]; then
    echo "The share ${share} doesn't exist: create it in the NAS dashboard (Shares), or set RECORDINGS in" \
        "${PROJECT}/.env to a folder on another share, then run this again"

    exit 1
fi

mkdir -p "${recordings}" "$(setting CONFIG_LOCATION)"

cd "${PROJECT}"

# Runs one of the recipe's hooks as the Store does: in this folder, with .env's variables in its environment (read as
# values, never run as shell code) and STORE_ACTION.
#
# $1 hook The hook's file name in hooks/
#
# Prints its output; returns its exit code
run_hook() {
    (
        while IFS= read -r line; do
            case "${line}" in
                [A-Z]*=*)
                    key="${line%%=*}"
                    export "${key}=$(setting "${key}")"
                    ;;
            esac
        done < "${PROJECT}/.env"
        export STORE_ACTION="${ACTION}"
        sh "${RECIPE_PATH}/hooks/$1"
    )
}

# Ports 8971 and 8554 must be free - unless it's this Frigate that has them (running it again); and its first settings
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
    run_hook pre_install.sh
fi

echo "Starting Frigate (the first time, Docker downloads Frigate's image - about 3GB, 9GB once unpacked)"
docker compose pull
docker compose up -d
run_hook configure.sh || true

# Its site in the Nginx app, if installed (responses passed on as they come: live video) - as the Store does for
# recipe.json's web.nginx
if [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
    if php "${APPS_PATH}/nginx/lib/sites.php" add-app "${APPS_PATH}/_nginx" cameras http://127.0.0.1:8971 'Frigate' \
        --stream; then
        sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
        url="$(php "${APPS_PATH}/nginx/lib/sites.php" url "${APPS_PATH}/_nginx" cameras)" \
            && echo "Added Frigate's site to the Nginx app: ${url}" \
            || echo "Added Frigate's site to the Nginx app (cameras.<domain>, once a domain is set on its page)"
    fi
fi

echo 'Frigate is starting: http://<nas-ip>:8971 in a minute or two (user: admin).' \
    'Then add your cameras (Settings -> Cameras)'
