#!/bin/sh
# Before a new install (the Store's pre_install hook, also run by setup.sh): the ports the apps use must be free on the
# NAS, and Seerr's and Recyclarr's settings folders must be their user's (they don't run as root, unlike the other
# images' set-up). Run in the recipe's folder, with .env's variables in the environment.

# Whether a TCP port (in hex) is in use, from the kernel's own tables
in_use() {
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v port="$1" 'NR > 1 { split($2, local, ":"); if (toupper(local[2]) == port && $4 == "0A") found = 1 } END { exit !found }'
}

check() {
    if in_use "$(printf '%04X' "$2")"; then
        echo "Port $2 ($1) is already used on the NAS - the Arr stack needs it"

        exit 1
    fi
}

check qBittorrent 8090; check "qBittorrent's torrents" "${TORRENT_PORT:-6881}"; check Prowlarr 9696; check Sonarr 8989
check Radarr 7878; check Bazarr 6767; check Seerr 5055
[ "${LIDARR}" = on ] && check Lidarr 8686
[ "${BOOKS}" = on ] && check Bookshelf 8787
[ "${SABNZBD}" = on ] && check SABnzbd 8085

mkdir -p "${CONFIG_ROOT}/seerr" "${CONFIG_ROOT}/recyclarr"
chown "${PUID}:${PGID}" "${CONFIG_ROOT}/seerr" "${CONFIG_ROOT}/recyclarr"
echo 'The ports are free'
