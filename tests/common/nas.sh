#!/bin/sh
# Shared by the app suites (sourced by their test_app.sh): a stand-in for the NAS, the app installed from its package as
# WD's installer does, and its management page served as the dashboard serves it.
#
#     . /t/common/nas.sh <app>      - then: install_app, page_up, get, post, j, code, pass, fail, wait_port
#
# A suite of apps that work together installs the others first (install_app <other>: their packages are listed in
# tests/<app>/with) and switches the page helpers between them (page_up <other>).
#
# The stand-in: BusyBox's sh, adduser, addgroup, ps and ip first in the PATH (as the NAS's), the share group,
# /dev/urandom and /dev/random readable by root only (as WD has them), root's crontab, a Public share
APP="$1"; SUITE="$1"
P=/mnt/HD/HD_a2/Nas_Prog; D=$P/_$APP; V=/mnt/HD/HD_a2
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
mkdir -p /tmp/bb && for tool in sh adduser addgroup ps ip; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
export PATH=/tmp/bb:$PATH
grep -q '^share:' /etc/group || echo 'share:x:1000:' >> /etc/group
chmod 600 /dev/urandom /dev/random
mkdir -p $P/_install/$APP $V/Public /var/spool/cron/crontabs /var/www/apps && touch /var/spool/cron/crontabs/root
chmod 777 $V/Public

# Installs, initialises and starts the app (or the other app given) from its package, as WD's installer does (logs in
# /tmp/<step>.log)
install_app() {
    app=${1:-$SUITE}; package=/pkg/package.tar.gz
    [ "$app" = "$SUITE" ] || package=/pkg/$app.tar.gz
    mkdir -p $P/_install/$app && tar -xzf $package -C $P/_install/$app
    cd $P && sh $P/_install/$app/install.sh $P/_install/$app $P > /tmp/install.log 2>&1
    sh $P/$app/init.sh $P/$app > /tmp/init.log 2>&1
    sh $P/$app/start.sh $P/$app > /tmp/start.log 2>&1
    cd /
}

# Whether something answers on a TCP port; wait_port <port> [seconds] waits for it
listening() {
    [ -n "$(awk -v port="$(printf '%04X' "$1")" 'NR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)" ]
}
wait_port() {
    i=0; while [ $i -lt "${2:-120}" ]; do listening "$1" && return 0; sleep 1; i=$((i + 1)); done; return 1
}

# The app's management page, for a NAS admin's WD session, with its CSRF token: page_up, then get <action> [&params],
# post <action> [curl options]; j <php expression on $d> reads the JSON on its input; code prints a request's status
page_up() {
    [ -n "${1:-}" ] && APP=$1 && D=$P/_$1

    if ! listening 8080; then
        echo 'administrators:x:1001:admin' >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
        (php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/phpserver.log 2>&1 &)
        sleep 1
    fi
    PAGE=http://127.0.0.1:8080/apps/$APP; CK='Cookie: PHPSESSID=adminsession123'
    T=$(curl -s -H "$CK" $PAGE/index.php | sed -n 's/.*let csrf *= "\([^"]*\)".*/\1/p')
    # The page's script finds its part of the page by <app>-manage (lower case): any other id leaves the page empty
    curl -s -H "$CK" $PAGE/index.php | grep -q "id=\"$(echo "$APP" | tr 'A-Z' 'a-z')-manage\"" \
        || fail "${1:+$1: }its page has no <div id=\"$(echo "$APP" | tr 'A-Z' 'a-z')-manage\"> (its script would find nothing to fill in)"

    # A page that only shows things - READ_ONLY_PAGE=1 - has no actions, so no CSRF token
    if [ -n "${READ_ONLY_PAGE:-}" ]; then
        [ "$(code -H 'X-Requested-With: XMLHttpRequest' "$PAGE/api.php?action=status")" = 403 ] && [ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$PAGE/api.php?action=status")" = 200 ] \
            && pass "${1:+$1: }its page: refused without a NAS login" || fail 'page: not refused, or not shown'

        return
    fi
    [ -n "$T" ] && [ "$(code -H 'X-Requested-With: XMLHttpRequest' "$PAGE/api.php?action=status")" = 403 ] \
        && [ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d x=1 "$PAGE/api.php?action=restart")" = 403 ] \
        && pass "${1:+$1: }its page: refused without a NAS login, or with a wrong CSRF token" || fail 'page: no CSRF token, or not refused'
}
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$PAGE/api.php?action=$1${2:-}"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$PAGE/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Its life after the suite's checks (or the other app's given): stop, clean, remove - stopped, its data kept
finish_app() {
    app=${1:-$SUITE}
    sh $P/$app/stop.sh $P/$app > /dev/null 2>&1; sh $P/$app/clean.sh $P/$app > /dev/null 2>&1; sh $P/$app/remove.sh $P/$app > /dev/null 2>&1
    [ ! -d $P/$app ] && [ -d $P/_$app ] && pass "${1:+$1 }removed, its data kept ($(ls $P/_$app | tr '\n' ' ' | cut -c1-80))" || fail "remove $app"
}
