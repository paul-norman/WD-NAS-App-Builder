#!/bin/sh
# Copies a share to a USB drive every night: new and changed files are copied, nothing is deleted from the drive.
# Set the two folders below (the NAS's USB drives are in /mnt/USB - e.g. ls /mnt/USB over SSH), then switch it on.
FROM=/mnt/HD/HD_a2/Public
TO=/mnt/USB/USB1_c1/Backup/Public

# A drive that isn't plugged in fails the task (rather than filling the NAS's own folder)
DRIVE="$(echo "${TO}" | cut -d / -f 1-4)"

if ! grep -q " ${DRIVE} " /proc/mounts; then
    echo "The USB drive isn't plugged in: ${DRIVE}"

    exit 1
fi

mkdir -p "${TO}"
rsync -a --stats "${FROM}/" "${TO}/"
