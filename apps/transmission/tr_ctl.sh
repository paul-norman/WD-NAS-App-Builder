#!/bin/sh
# Runs Transmission (BitTorrent) as its own user, in the NAS's share group, with its data in the persistent path
# Nas_Prog/_transmission - kept across reinstalls. Run by the app's scripts and its management page:
#   tr_ctl.sh setup        - create its user, folders, settings and web interface password (where missing)
#   tr_ctl.sh start        - write its settings into Transmission's own, then start it (web interface on port 9091)
#   tr_ctl.sh stop         - stop Transmission (it saves its torrents' progress first)
#   tr_ctl.sh restart      - stop, then start
#   tr_ctl.sh new-password - generate a new web interface password (applied when Transmission next starts; at once for
#                            the Nginx app's site, which asks for the same login before passing anything on)
#   tr_ctl.sh daily        - the daily job: keeping its log small
#   tr_ctl.sh nginx        - add / update Transmission's site in the Nginx app (and reload it)
#
# Its downloads go to a folder in the shares (a Downloads share if there is one, else Public/Downloads), readable and
# writable by the NAS's users: Transmission runs in the share group, with a umask that keeps its files group-writable

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
VOLUME_PATH="$(dirname "${APPS_PATH}")"
DATA_PATH="${APPS_PATH}/_transmission"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries/bin"
WEB="${APP_PATH}/binaries/share/transmission/public_html"
CONFIG_DIR="${DATA_PATH}/config"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/password"
# The same login for the Nginx app's site (its nginx.json's auth_file): Nginx asks for it first, so visits without it
# (e.g. a browser's first request, before it asks for the password) stop there rather than filling Transmission's log
HTPASSWD="${DATA_PATH}/htpasswd"
TR_LOG="${DATA_PATH}/transmission.log"
PID_FILE=/var/run/transmission.pid
PORT=9091
# Its own user (created if missing): the ID used when creating it. Its group is the NAS's share group if there is one
TR_ID=97
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') transmission/tr_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. DOWNLOAD_DIR)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether Transmission is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The transmission user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
tr_ids() {
    awk -F: '$1 == "transmission" { print $3 " " $4 }' /etc/passwd
}

# The group Nginx's worker processes run as: nobody's own (nogroup on Debian - WD's NAS has none by that name: there it's
# the share users' group), by its ID, as the Nginx app picks it.
#
# Prints the group ID
nginx_gid() {
    awk -F: '$1 == "nobody" { print $4 }' /etc/passwd
}

# Writes the htpasswd file for the Nginx app's site: user admin with the app's password, as SHA-512 crypt (Nginx checks
# it on every request, so not a slow hash like bcrypt). Root's, readable by Nginx's workers (their group).
#
# Returns 0 once it's written
write_htpasswd() {
    local hash gid

    gid="$(nginx_gid)"

    if [ -z "${gid}" ]; then
        log "No nobody user on the NAS: Nginx's workers couldn't read the password file"

        return 1
    fi

    hash="$(php -n -r '$salt = substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16);
        echo crypt(trim((string)file_get_contents($argv[1])), "\$6\$rounds=5000\$" . $salt . "\$");' "${PASSWORD_FILE}")"

    case "${hash}" in
        '$6$'*) ;;
        *) log 'Could not hash the password for the Nginx site (is PHP working?)'; return 1 ;;
    esac

    printf 'admin:%s\n' "${hash}" > "${HTPASSWD}.tmp" && chgrp "${gid}" "${HTPASSWD}.tmp" && chmod 640 "${HTPASSWD}.tmp" \
        && mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

new_password() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSWORD_FILE}.tmp" ) \
        && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
    log 'generated a new web interface password'
    write_htpasswd
}

# The downloads folder to start with: a Downloads share if the volume has one, else Public/Downloads.
#
# Prints it
default_download_dir() {
    if [ -d "${VOLUME_PATH}/Downloads" ]; then
        echo "${VOLUME_PATH}/Downloads"
    else
        echo "${VOLUME_PATH}/Public/Downloads"
    fi
}

setup() {
    local group download_dir

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot), in the share group - or its own
    # group, on a NAS without one
    if ! grep -q '^transmission:' /etc/passwd; then
        group=share

        if ! grep -q '^share:' /etc/group; then
            group=transmission
            grep -q '^transmission:' /etc/group || addgroup -g ${TR_ID} transmission
        fi

        adduser -D -H -h /nonexistent -s /bin/false -u ${TR_ID} -G ${group} transmission
    fi

    if [ -z "$(tr_ids)" ]; then
        log "Could not create the transmission user (is ID ${TR_ID} already taken?)"

        return 1
    fi

    set -- $(tr_ids)

    # Its own data (Transmission's settings, torrents and their progress) belongs to its user; the page's settings and
    # the password to root
    mkdir -p "${CONFIG_DIR}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'DOWNLOAD_DIR=%s\nLISTEN=all\nPEER_PORT=51413\nDOWN_LIMIT=0\nUP_LIMIT=0\n' "$(default_download_dir)" \
            > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_password

    # The Nginx site's copy of the login (made again if the password is newer, e.g. from an earlier version of the app)
    if [ ! -s "${HTPASSWD}" ] || [ "${PASSWORD_FILE}" -nt "${HTPASSWD}" ]; then
        write_htpasswd
    fi

    # Its queue's order: Transmission only writes queue.json once torrents have been queued, and logs an error at every
    # start while it's missing - an empty list is what it reads a missing file as
    if [ ! -f "${CONFIG_DIR}/queue.json" ]; then
        printf '[]\n' > "${CONFIG_DIR}/queue.json" && chown "$1:$2" "${CONFIG_DIR}/queue.json" \
            && chmod 600 "${CONFIG_DIR}/queue.json"
    fi
    touch "${TR_LOG}"
    chmod 600 "${TR_LOG}"

    # The downloads folder (made the first time, in the share group, writable by it)
    download_dir="$(setting DOWNLOAD_DIR "$(default_download_dir)")"

    if [ ! -d "${download_dir}" ]; then
        log "creating the downloads folder: ${download_dir}"
        mkdir -p "${download_dir}" && chown "$1:$2" "${download_dir}" && chmod 2775 "${download_dir}"
    fi
}

# Writes the app's settings into Transmission's own settings.json (while it's stopped: Transmission writes the file
# again when it stops), keeping everything else in it - e.g. what was changed in its web interface.
#
# Prints nothing; returns 1 if it couldn't be written
write_config() {
    local host=0.0.0.0

    set -- $(tr_ids)
    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1

    # (PHP: the NAS always has it; the password is read from its file, not given on a command line)
    php -r '
        $file = $argv[1];
        $settings = is_file($file) ? json_decode((string)file_get_contents($file), true) : [];
        $settings = is_array($settings) ? $settings : [];
        $down = (int)$argv[5];
        $up = (int)$argv[6];
        $settings = array_merge($settings, [
            "download-dir"                => $argv[2],
            "incomplete-dir-enabled"      => false,
            "rpc-enabled"                 => true,
            "rpc-bind-address"            => $argv[3],
            "rpc-port"                    => 9091,
            "rpc-authentication-required" => true,
            "rpc-username"                => "admin",
            "rpc-password"                => trim((string)file_get_contents($argv[7])),
            "rpc-whitelist-enabled"       => false,
            "rpc-host-whitelist-enabled"  => false,
            "peer-port"                   => (int)$argv[4],
            "peer-port-random-on-start"   => false,
            "speed-limit-down"            => $down,
            "speed-limit-down-enabled"    => $down > 0,
            "speed-limit-up"              => $up,
            "speed-limit-up-enabled"      => $up > 0,
            "umask"                       => "002",
        ]);
        exit(file_put_contents($file.".tmp", json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n") === false ? 1 : 0);
    ' "${CONFIG_DIR}/settings.json" "$(setting DOWNLOAD_DIR "$(default_download_dir)")" "${host}" \
        "$(setting PEER_PORT 51413)" "$(setting DOWN_LIMIT 0)" "$(setting UP_LIMIT 0)" "${PASSWORD_FILE}" || return 1

    chmod 600 "${CONFIG_DIR}/settings.json.tmp"
    chown "$1:$2" "${CONFIG_DIR}/settings.json.tmp" && mv -f "${CONFIG_DIR}/settings.json.tmp" "${CONFIG_DIR}/settings.json"
}

start() {
    if running; then
        log "Transmission is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1

    if ! write_config; then
        log 'Could not write its settings (is PHP working?)'

        return 1
    fi

    set -- $(tr_ids)
    log "starting Transmission on port ${PORT} (log: ${TR_LOG})"
    cd "${CONFIG_DIR}" || return 1
    ( exec env HOME="${CONFIG_DIR}" TRANSMISSION_WEB_HOME="${WEB}" "${BIN}/tr_runas" "$1" "$2" \
        "${BIN}/transmission-daemon" --foreground --config-dir "${CONFIG_DIR}" --log-level=warn ) >> "${TR_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Transmission started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Transmission (PID ${pid})"
        kill "${pid}"

        # It tells the trackers it's stopping and saves its torrents' progress first
        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${waited}" -ge 30 ]; then
                log 'Transmission did not stop within 30 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Keeps Transmission's log under 1MB (the previous part is kept as transmission.log.1).
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${TR_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${TR_LOG}" "${TR_LOG}.1" && : > "${TR_LOG}"
        chmod 600 "${TR_LOG}.1"
    fi
}

# The Nginx app finds Transmission by its folder and serves it at https://torrents.<its domain>: rewrite its sites.
#
# Prints nothing
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart)
        stop
        start
        ;;
    new-password) new_password ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|daily|nginx" >&2

        exit 1
        ;;
esac
