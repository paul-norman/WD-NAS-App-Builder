#!/bin/sh
# Sets Linkwarden up on the NAS (with the Docker and Nginx apps installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/linkwarden/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_linkwarden, creates .env there from example.env (with generated
# secrets, and the admin password it asks for - only the first time: an existing .env is kept), creates the folders,
# starts Linkwarden, makes its admin account (hooks/post_install.sh) and adds its site to the Nginx app
# (https://links.<domain>). Running it again is safe (e.g. after changing .env).
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_linkwarden
APPS_PATH=/mnt/HD/HD_a2/Nas_Prog

# A setting from .env (without quotes around it).
#
# $1 name The setting
#
# Prints its value
setting() {
    sed -n "s/^$1=//p" "${PROJECT}/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'$/\\1/"
}

# A secret: letters and digits.
#
# $1 length The number of characters
#
# Prints it
secret() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"
}

if ! docker compose version > /dev/null 2>&1; then
    echo "Docker (with docker compose) isn't available: install or start the Docker app first"

    exit 1
fi

if [ ! -f "${APPS_PATH}/nginx/lib/sites.php" ]; then
    echo 'Linkwarden is reached through the Nginx app: install it first'

    exit 1
fi

mkdir -p "${PROJECT}"
chmod 700 "${PROJECT}"
cp "${RECIPE_PATH}/compose.yaml" "${PROJECT}/compose.yaml"

if [ ! -f "${PROJECT}/.env" ]; then
    printf 'Linkwarden admin password (8 characters or more, letters and digits): '
    read -r password

    case "${password}" in
        ???????? | ?????????*) ;;
        *)
            echo 'Too short'

            exit 1
            ;;
    esac

    case "${password}" in
        *[!A-Za-z0-9]*)
            echo 'Letters and digits only here (change it in Linkwarden afterwards if you like)'

            exit 1
            ;;
    esac

    ( umask 077; sed -e "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${password}/" \
        -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(secret 32)/" \
        -e "s/^NEXTAUTH_SECRET=.*/NEXTAUTH_SECRET=$(secret 48)/" \
        -e "s/^MEILI_MASTER_KEY=.*/MEILI_MASTER_KEY=$(secret 32)/" \
        "${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
    echo "Created ${PROJECT}/.env"
fi

chmod 600 "${PROJECT}/.env"
mkdir -p "$(setting DATA_LOCATION)" "$(setting PG_LOCATION)" "$(setting MEILI_LOCATION)"

cd "${PROJECT}"
echo 'Starting Linkwarden'
docker compose pull
docker compose up -d

# Its admin account (a new install only) and its address - with .env's variables in the environment, as the Store runs
# its hooks
( set -a; . ./.env; set +a; sh "${RECIPE_PATH}/hooks/post_install.sh" )

# Its site in the Nginx app - as the Store does for recipe.json's web.nginx
if [ -d "${APPS_PATH}/_nginx/sites" ] \
    && php "${APPS_PATH}/nginx/lib/sites.php" add-app "${APPS_PATH}/_nginx" links http://127.0.0.1:3003 Linkwarden \
        --uploads; then
    sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
    sh "${RECIPE_PATH}/hooks/site.sh"
    url="$(php "${APPS_PATH}/nginx/lib/sites.php" url "${APPS_PATH}/_nginx" links)" \
        && echo "Linkwarden is at: ${url}" \
        || echo 'Linkwarden is at links.<domain>, once a domain is set on the Nginx app'"'"'s page'
fi
