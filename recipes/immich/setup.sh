#!/bin/sh
# Sets Immich up on the NAS (with the Docker app installed): run from this folder, e.g.
#     sh /mnt/HD/HD_a2/Public/immich/setup.sh
#
# It copies compose.yaml to /mnt/HD/HD_a2/Nas_Prog/_immich, creates .env there from example.env (with a generated
# database password - only the first time: an existing .env is kept), creates the folders, starts Immich, and adds its
# site to the Nginx app (https://photos.<domain>), if installed. Running it again is safe (e.g. after changing .env).
# (It's the manual way: the Store app installs recipes from recipe.json, with a wizard - see store/SPEC.md)

set -e

RECIPE_PATH="$(dirname "$(readlink -f "$0")")"
PROJECT=/mnt/HD/HD_a2/Nas_Prog/_immich
APPS_PATH=/mnt/HD/HD_a2/Nas_Prog

# A setting from .env (without quotes around it)
setting() {
	sed -n "s/^$1=//p" "${PROJECT}/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'$/\\1/"
}

# A string for compose.override.yaml: double quoted, and $ doubled (Compose would read ${...} as a variable)
yaml_string() {
	printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/$$/g')"
}

if ! docker compose version > /dev/null 2>&1; then
	echo "Docker (with docker compose) isn't available: install or start the Docker app first"
	exit 1
fi

mkdir -p "${PROJECT}"
chmod 700 "${PROJECT}"
cp "${RECIPE_PATH}/compose.yaml" "${PROJECT}/compose.yaml"

if [ ! -f "${PROJECT}/.env" ]; then
	# (the database password: letters and digits, written straight into the root-only .env)
	( umask 077; sed "s/^DB_PASSWORD=.*/DB_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)/" \
		"${RECIPE_PATH}/example.env" > "${PROJECT}/.env" )
	echo "Created ${PROJECT}/.env (with a generated database password) - edit it to change where the photos go, then run this again"
fi

chmod 600 "${PROJECT}/.env"

# The photos go in a folder on a share: the share itself must exist (created in the NAS dashboard, so that it's shared)
upload="$(setting UPLOAD_LOCATION)"
share="$(echo "${upload}" | cut -d/ -f1-5)"

if [ ! -d "${share}" ]; then
	echo "The share ${share} doesn't exist: create it in the NAS dashboard (Shares), or set UPLOAD_LOCATION in ${PROJECT}/.env to a folder on another share, then run this again"
	exit 1
fi

mkdir -p "${upload}" "$(setting DB_DATA_LOCATION)" "$(setting MODEL_CACHE_LOCATION)"

# Existing photo folders (EXTERNAL_PHOTOS, separated by |): given to the server read only, in compose.override.yaml -
# which docker compose reads together with compose.yaml by itself. Each is at /external followed by its path on the NAS
# (relative to /mnt/HD/HD_a2, or to /mnt for other disks), as the Store does for the recipe's "mount" options
override="${PROJECT}/compose.override.yaml"
mounts=""
old_ifs="${IFS}"
IFS="|"
set -f
for folder in $(setting EXTERNAL_PHOTOS); do
	folder="${folder%/}"
	[ -n "${folder}" ] || continue
	case "${folder}" in
		*/../*|*/..|*/./*|*/.) echo "EXTERNAL_PHOTOS: ${folder} - use the folder's full path, without . or .. in it"; exit 1 ;;
		/mnt/HD/HD_a2/Nas_Prog|/mnt/HD/HD_a2/Nas_Prog/*|/mnt/HD/HD_a2/.*) echo "EXTERNAL_PHOTOS: ${folder} is one of the NAS's own folders - use a folder on a share"; exit 1 ;;
		/mnt/HD/HD_a2/?*) target="/external/${folder#/mnt/HD/HD_a2/}" ;;
		/mnt/HD/?*/?*|/mnt/USB/?*) target="/external/${folder#/mnt/}" ;;
		*) echo "EXTERNAL_PHOTOS: ${folder} isn't a folder on the NAS's shares (e.g. /mnt/HD/HD_a2/Photos)"; exit 1 ;;
	esac
	if [ ! -d "${folder}" ]; then
		echo "EXTERNAL_PHOTOS: ${folder} doesn't exist"
		exit 1
	fi
	mounts="${mounts}      - type: bind
        source: $(yaml_string "${folder}")
        target: $(yaml_string "${target}")
        read_only: true
"
	echo "Existing photos: ${folder} - in Immich as ${target}"
done
set +f
IFS="${old_ifs}"
if [ -n "${mounts}" ]; then
	printf '# Written by setup.sh from EXTERNAL_PHOTOS in .env (rewritten each time - change .env instead)\nservices:\n  immich-server:\n    volumes:\n%s' "${mounts}" > "${override}"
else
	rm -f "${override}"
fi

cd "${PROJECT}"

echo "Starting Immich (the first time, Docker downloads about 3GB of images - this takes a while)"

docker compose pull
docker compose up -d

# On a new install, face recognition starts off unless FACIAL_RECOGNITION=on - the recipe's post_install hook (as the
# Store runs it: in this folder, with .env's variables in its environment - read as values, never run as shell code)
(
	while IFS= read -r line; do
		case "${line}" in
			[A-Z]*=*) key="${line%%=*}"; export "${key}=$(setting "${key}")" ;;
		esac
	done < "${PROJECT}/.env"
	sh "${RECIPE_PATH}/hooks/post_install.sh"
) || true

# Its site in the Nginx app, if installed (uploads: no size limit, long time-outs) - as the Store does for recipe.json's
# web.nginx
if [ -f "${APPS_PATH}/nginx/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
	if php "${APPS_PATH}/nginx/lib/sites.php" add-app "${APPS_PATH}/_nginx" photos http://127.0.0.1:2283 "Immich" --uploads; then
		sh "${APPS_PATH}/nginx/nginx_ctl.sh" reload > /dev/null 2>&1
		url="$(php "${APPS_PATH}/nginx/lib/sites.php" url "${APPS_PATH}/_nginx" photos)" \
			&& echo "Added Immich's site to the Nginx app: ${url}" \
			|| echo "Added Immich's site to the Nginx app (photos.<domain>, once a domain is set on its page)"
	fi
fi

echo "Immich is starting: http://<nas-ip>:2283 in a minute or two (the first visit creates its admin user)"
if [ -n "${mounts}" ]; then
	echo "To show the existing photos: Administration -> External Libraries -> Create Library, then add the folders above (as /external/...)"
fi
