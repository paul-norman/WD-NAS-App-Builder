#!/bin/sh
# Shared by the tests on the stand-in NAS: its paths, and the management page's API as the dashboard calls it (an admin's
# WD session and the page's CSRF token)
A=/mnt/HD/HD_a2/Nas_Prog/wireguard; D=/mnt/HD/HD_a2/Nas_Prog/_wireguard
export PATH=/tmp/bb:$PATH
B=http://127.0.0.1:8080/apps/wireguard; CK='Cookie: PHPSESSID=adminsession123'
T=$(cat /tmp/csrf 2>/dev/null)
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
