#!/bin/sh
# Fails - so ntfy tells you, if it's set up below the tasks - when a volume of the NAS is fuller than the limit.
LIMIT=90
FULL=0

for volume in /mnt/HD/HD_*2; do
    [ -d "${volume}" ] || continue
    used="$(df -P "${volume}" | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
    echo "${volume}: ${used}% used"

    if [ "${used}" -ge "${LIMIT}" ]; then
        FULL=1
    fi
done

if [ "${FULL}" = 1 ]; then
    echo "A volume is over ${LIMIT}% full"

    exit 1
fi
