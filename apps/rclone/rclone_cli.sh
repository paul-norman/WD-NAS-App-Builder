#!/bin/sh
# The rclone command (linked as /usr/bin/rclone by init.sh), for SSH: rclone with the app's own config file - the remotes
# its web interface and jobs use. Run by root, it runs as rclone's own user (as the app's jobs do), so that the config
# stays readable by it and what it writes in the shares stays the share group's:
#     rclone config                         - set up a remote (or use the web interface)
#     rclone ls remote:path                 - and every other rclone command
APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_rclone"
IDS="$(awk -F: '$1 == "rclone" { print $3 " " $4 }' /etc/passwd)"

if [ "$(id -u)" = 0 ] && [ -n "${IDS}" ]; then
    set -- ${IDS} "${APP_PATH}/binaries/rclone" --config "${DATA_PATH}/config/rclone.conf" \
        --cache-dir "${DATA_PATH}/cache" "$@"
    cd /tmp || exit 1

    exec env HOME="${DATA_PATH}/config" "${APP_PATH}/binaries/rclone_runas" "$@"
fi

exec "${APP_PATH}/binaries/rclone" --config "${DATA_PATH}/config/rclone.conf" "$@"
