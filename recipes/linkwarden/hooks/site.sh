#!/bin/sh
# Writes site.env - Linkwarden's address, for its sign-in (secure cookies over HTTPS) and the links it makes - and, when
# it changed, recreates Linkwarden's container to use it. The address is the Nginx app's site for it (as the Store
# names it, or https://links.<domain> before the Store has added it), else the NAS itself. The Store's post_update and
# post_change hook, and part of post_install; run in the recipe's folder (setup.sh runs it too). Running it again after
# the Nginx app's domain changed brings it up to date.

APPS_PATH="$(dirname "$(pwd)")"
SITES="${APPS_PATH}/nginx/lib/sites.php"
url=''

if [ -f "${SITES}" ] && [ -d "${APPS_PATH}/_nginx" ]; then
    url="$(php "${SITES}" url "${APPS_PATH}/_nginx" links 2>/dev/null)"

    # (not added yet: its usual address, from the Nginx app's domain)
    if [ -z "${url}" ]; then
        domain="$(php -r 'require $argv[1]; $s = sites_load($argv[2]); echo $s["domain"];' "${SITES}" \
            "${APPS_PATH}/_nginx" 2>/dev/null)"
        [ -n "${domain}" ] && url="https://links.${domain}/"
    fi
fi

url="${url%/}"
[ -n "${url}" ] || url='http://127.0.0.1:3003'

new="$(printf 'NEXTAUTH_URL=%s/api/v1/auth\nBASE_URL=%s\n' "${url}" "${url}")"

if [ "${new}" != "$(cat site.env 2>/dev/null)" ]; then
    printf '%s\n' "${new}" > site.env
    chmod 644 site.env
    echo "Linkwarden's address: ${url}"

    # (its container reads it when it's made: a running one is made again)
    if [ -n "$(docker compose ps -q linkwarden 2>/dev/null)" ]; then
        docker compose up -d linkwarden
    fi
fi

exit 0
