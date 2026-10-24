#!/bin/sh
# Sets the Arr stack up on the NAS (with the Docker app installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/arr/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_arr, creates .env there from example.env (with a generated password,
# shown once, and API keys - only the first time: an existing .env is kept), checks the ports, starts the apps, connects
# them to each other (hooks/wire.py - as the Store does), and adds Seerr's site to the Nginx app
# (https://requests.<domain>), if installed. Running it again is safe, and applies changes made to .env.
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_arr
APPS_PATH=/mnt/HD/HD_a2/Nas_Prog

# A setting from .env (without quotes around it)
setting() {
	sed -n "s/^$1=//p" "${PROJECT}/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'$/\\1/"
}

random() {
	tr -dc "$1" < /dev/urandom | head -c "$2"
}

if ! docker compose version > /dev/null 2>&1; then
	echo "Docker (with docker compose) isn't available: install or start the Docker app first"
	exit 1
fi

mkdir -p "${PROJECT}"
chmod 700 "${PROJECT}"
cp "${RECIPE_PATH}/compose.yaml" "${PROJECT}/compose.yaml"

new=""
if [ ! -f "${PROJECT}/.env" ]; then
	password="$(random 'A-Za-z0-9' 16)"
	( umask 077; sed -e "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${password}/" "${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
	for app in PROWLARR SONARR RADARR LIDARR BOOKSHELF; do
		sed -i "s/^${app}_API_KEY=$/${app}_API_KEY=$(random 'a-f0-9' 32)/" "${PROJECT}/.env"
	done
	echo "Created ${PROJECT}/.env - the password for every app is: ${password} (user admin)"
	new=1
fi

chmod 600 "${PROJECT}/.env"

data="$(setting DATA_ROOT)"
share="$(echo "${data}" | cut -d/ -f1-5)"
if [ ! -d "${share}" ]; then
	echo "The share ${share} doesn't exist: create it in the NAS dashboard (Shares), or set DATA_ROOT in ${PROJECT}/.env to a folder on another share, then run this again"
	exit 1
fi
mkdir -p "${data}"

cd "${PROJECT}"

# The hooks run with .env's variables in their environment (read as values, never run as shell code)
with_env() {
	(
		while IFS= read -r line; do
			case "${line}" in
				[A-Z]*=*) key="${line%%=*}"; export "${key}=$(setting "${key}")" ;;
			esac
		done < "${PROJECT}/.env"
		export STORE_DATA="${PROJECT}"
		"$@"
	)
}

# Ports free (unless it's this stack that has them - running it again) and Seerr's folder
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
	with_env sh "${RECIPE_PATH}/hooks/pre_install.sh"
else
	with_env sh -c 'mkdir -p "${CONFIG_ROOT}/seerr" && chown "${PUID}:${PGID}" "${CONFIG_ROOT}/seerr"'
fi

echo "Starting the Arr stack (the first time, Docker downloads about 3GB of images - this takes a while)"
docker compose pull
docker compose up -d
echo "Connecting the apps to each other"
with_env sh "${RECIPE_PATH}/hooks/wire.sh" || true

# Seerr's site in the Nginx app, if installed - as the Store does for recipe.json's web.nginx
if [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
	if php "${APPS_PATH}/nginx/lib/sites.php" add-app "${APPS_PATH}/_nginx" requests http://127.0.0.1:5055 "Seerr"; then
		sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
		url="$(php "${APPS_PATH}/nginx/lib/sites.php" url "${APPS_PATH}/_nginx" requests)" \
			&& echo "Added Seerr's site to the Nginx app: ${url}" \
			|| echo "Added Seerr's site to the Nginx app (requests.<domain>, once a domain is set on its page)"
	fi
fi

echo "Done. Next: add indexers in Prowlarr (http://<nas-ip>:9696), then open Seerr (http://<nas-ip>:5055) to choose your media server"
[ -n "${new}" ] && echo "Point Jellyfin or Plex at ${data}/media"
true
