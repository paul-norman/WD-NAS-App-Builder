#!/bin/sh
# Shared by the tests: a stand-in for the NAS - the app's files where the NAS installs it (when given in /app; its
# binaries are mounted at binaries/), BusyBox's user tools (the image's own BusyBox has no adduser), and WD's shares:
# open to all (0777, root's), with the share group every NAS user is in
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in adduser addgroup ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:$PATH
grep -q '^share:' /etc/group || echo 'share:x:1000:' >> /etc/group
mkdir -p /mnt/HD/HD_a2/Nas_Prog /mnt/HD/HD_a2/Public /mnt/HD/HD_a2/Family
chmod 777 /mnt/HD/HD_a2/Nas_Prog /mnt/HD/HD_a2/Public /mnt/HD/HD_a2/Family
[ -d /app ] && mkdir -p /mnt/HD/HD_a2/Nas_Prog/copyparty && cp -r /app/. /mnt/HD/HD_a2/Nas_Prog/copyparty/
true
