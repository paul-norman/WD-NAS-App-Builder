#!/bin/sh
# Shared by the tests: a stand-in for the NAS - the app's files where the NAS installs it (when given in /app; its
# binaries are mounted at binaries/), and BusyBox's user tools (the image's own BusyBox has no adduser)
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in adduser addgroup ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:$PATH
mkdir -p /mnt/HD/HD_a2/Nas_Prog /mnt/HD/HD_a2/Public
[ -d /app ] && mkdir -p /mnt/HD/HD_a2/Nas_Prog/calibre-web && cp -r /app/. /mnt/HD/HD_a2/Nas_Prog/calibre-web/
true
