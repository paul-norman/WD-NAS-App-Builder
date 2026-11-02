#!/bin/sh
# The stand-in NAS: the app's files where the NAS installs them (its binaries are mounted at binaries/), BusyBox's ip
# and user tools (as the NAS's), the management page served as the dashboard does (for an admin's session), and a small
# service answering with the address it sees requests come from (port 8099)
mkdir -p /tmp/bb && for tool in adduser addgroup ps; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
# IP forwarding off, as on a NAS without Docker running (so that the test sees WireGuard turn it on, and back off)
echo 0 > /proc/sys/net/ipv4/ip_forward
# The NAS's ip is BusyBox's, in /sbin
ln -sf /t/bb/busybox /sbin/ip
export PATH=/tmp/bb:$PATH
mkdir -p /mnt/HD/HD_a2/Nas_Prog/wireguard && cp -r /app/. /mnt/HD/HD_a2/Nas_Prog/wireguard/
mkdir -p /var/www/apps && ln -s /mnt/HD/HD_a2/Nas_Prog/wireguard/manage /var/www/apps/wireguard
echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
(php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &)
mkdir -p /tmp/who && echo '<?php echo $_SERVER["REMOTE_ADDR"];' > /tmp/who/index.php
(php -S 0.0.0.0:8099 -t /tmp/who > /tmp/who.log 2>&1 &)
sleep 1
curl -s -H 'Cookie: PHPSESSID=adminsession123' http://127.0.0.1:8080/apps/wireguard/index.php | sed -n 's/.*let csrf *= "\([^"]*\)".*/\1/p' > /tmp/csrf
echo "csrf: $(cat /tmp/csrf)"
