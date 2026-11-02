#!/bin/sh
# phpMyAdmin's site in the Nginx app (https://phpmyadmin.<its domain>/phpMyAdmin/ - the NAS's own web server serves it,
# also at http://<nas-ip>/phpMyAdmin/). Unless AUTH=0, that HTTPS address asks first for the user name and password set
# on the app's page (Nginx checks them) - before anyone reaches phpMyAdmin's login. Its settings and password are in the
# persistent path (Nas_Prog/_phpMyAdmin - kept across reinstalls):
#   pma_site.sh setup         - its settings and site password (where missing)
#   pma_site.sh set-password  - a new password for its site, read from the input (one line)
#   pma_site.sh nginx         - write its nginx.json, rewrite the Nginx app's sites, and reload it

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_phpMyAdmin"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/site_password"
HTPASSWD="${DATA_PATH}/htpasswd"
# The user name its site asks for (with the password set on the page)
AUTH_USER=admin
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') phpMyAdmin/pma_site.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# The group Nginx's worker processes run as: nobody's own (nogroup on Debian - WD's NAS has none by that name: there
# it's the share users' group), by its ID, as the Nginx app picks it
nginx_gid() {
    awk -F: '$1 == "nobody" { print $4 }' /etc/passwd
}

# Writes the password (from the input) and its site's htpasswd file: SHA-512 crypt - Nginx checks it on every request,
# so not a slow hash like bcrypt. Only root and Nginx's workers (their group) can read the htpasswd file; the password
# itself is root's, for the page to show
set_password() {
    password="$(head -n 1 | tr -d '\r\n')"

    case "${password}" in
        ''|*[!A-Za-z0-9._~-]*) log 'Passwords are letters, digits and . _ ~ - only'; return 1 ;;
    esac

    # The PHP app's PHP, or the NAS's own - both have SHA-512 crypt
    php="${APPS_PATH}/php/binaries/php"
    [ -x "${php}" ] || php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
    hash="$(printf '%s' "${password}" | "${php}" -n -r '$salt = substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16);
		echo crypt(stream_get_contents(STDIN), "\$6\$rounds=5000\$" . $salt . "\$");')"

    case "${hash}" in
        '$6$'*) ;;
        *) log 'Could not hash the password (is PHP working?)'; return 1 ;;
    esac

    if [ -z "$(nginx_gid)" ]; then
        log "No nobody user on the NAS: Nginx's workers couldn't read the password file"

        return 1
    fi

    umask 077
    printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}" || return 1
    printf '%s:%s\n' "${AUTH_USER}" "${hash}" > "${HTPASSWD}.tmp" && chgrp "$(nginx_gid)" "${HTPASSWD}.tmp" && chmod 640 "${HTPASSWD}.tmp" \
        && mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

setup() {
    # Its folder: root's, passable for Nginx's workers (to read the htpasswd file - the admin password stays root's)
    mkdir -p "${DATA_PATH}"
    chmod 751 "${DATA_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'AUTH=1\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"

    if [ ! -s "${PASSWORD_FILE}" ] || [ ! -s "${HTPASSWD}" ]; then
        log "generating the password for its HTTPS address (shown on the app's page)"
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 | set_password || return 1
    fi
}

# Its site in the Nginx app: its nginx.json (which the Nginx app reads), with its password file unless AUTH=0. The
# package's own asks for the password, until this has run
write_nginx_json() {
    auth=''
    [ "$(setting AUTH 1)" = 1 ] && auth=',
	"auth_file": "_phpMyAdmin/htpasswd"'
    printf '{\n\t"name": "phpmyadmin",\n\t"label": "phpMyAdmin",\n\t"target": "http://127.0.0.1:80",\n\t"path": "/phpMyAdmin/"%s\n}\n' "${auth}" \
        > "${APP_PATH}/nginx.json.tmp" && chmod 644 "${APP_PATH}/nginx.json.tmp" && mv -f "${APP_PATH}/nginx.json.tmp" "${APP_PATH}/nginx.json"
}

# The Nginx app finds phpMyAdmin by its folder (its nginx.json): rewrite its sites
nginx_site() {
    write_nginx_json
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        # The NAS's php, wherever it's called from - e.g. the page, with a short PATH
        php="$(PATH="/usr/bin:/bin:/usr/local/bin:${PATH}" command -v php)"
        "${php:-php}" "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    set-password) set_password ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|set-password|nginx" >&2

        exit 1
        ;;
esac
