#!/bin/sh
# One app's package, as WD's installer runs it (BusyBox sh), in a stand-in for the NAS: install, initialise and start;
# its check (apps.conf); its files' permissions, page and cron jobs; then stop, clean and remove - its data kept.
#     lifecycle.sh <app> <check>    (the package at /pkg/package.tar.gz; its data folder's name in $DATA_FOLDER)
A="$1"; CHECK="$2"
P=/mnt/HD/HD_a2/Nas_Prog
pass() { echo "PASS $A: $1"; }
fail() { echo "FAIL $A: $1"; }
# WD's NAS: BusyBox's sh and user tools first, the share group, /dev/urandom readable by root only, root's crontab, WD's
# settings database (a stand-in xmldbc: its cron jobs)
mkdir -p /tmp/bb && for tool in sh adduser addgroup ps ip; do ln -sf /t/bb/busybox /tmp/bb/$tool; done
ln -sf /t/xmldbc /tmp/bb/xmldbc
export PATH=/tmp/bb:$PATH
grep -q '^share:' /etc/group || echo 'share:x:1000:' >> /etc/group
chmod 600 /dev/urandom /dev/random
mkdir -p $P/_install/$A /mnt/HD/HD_a2/Public /var/spool/cron/crontabs /var/www/apps && touch /var/spool/cron/crontabs/root
chmod 777 /mnt/HD/HD_a2/Public

# Whether something answers on a TCP port
listening() {
    [ -n "$(awk -v port="$(printf '%04X' "$1")" 'NR > 1 { split($2, l, ":"); if (l[2] == port && $4 == "0A") print }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)" ]
}

echo '== install, initialise, start'
tar -xzf /pkg/package.tar.gz -C $P/_install/$A
cd $P && sh $P/_install/$A/install.sh $P/_install/$A $P > /tmp/install.log 2>&1
sh $P/$A/init.sh $P/$A > /tmp/init.log 2>&1
sh $P/$A/start.sh $P/$A > /tmp/start.log 2>&1
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' $P/$A/apkg.rc | tr -d '\r')"
[ -d $P/$A ] && [ ! -d $P/_install/$A ] && [ -n "$VERSION" ] && pass "installed into Nas_Prog/$A ($VERSION)" || fail "install: $(cat /tmp/install.log | tail -n 5)"

# Its files: root's, and not writable by other users (a package built on a Windows drive once had them all 0777)
WRITABLE="$(find $P/$A ! -type l -perm -o+w | head -n 5)"
OTHERS="$(find $P/$A ! -user root | head -n 3)"
[ -z "${WRITABLE}" ] && [ -z "${OTHERS}" ] && pass "its files are root's, and not writable by others" || fail "permissions: ${WRITABLE} ${OTHERS}"

# Its management page (if it has one), where nasAdmin requires a NAS login
if [ -d $P/$A/manage ]; then
    [ -L /var/www/apps/$A/index.php ] && [ -e /var/www/apps/$A/index.php ] && php -l $P/$A/manage/index.php > /dev/null \
        && pass "management page linked at /apps/$A/ (and its PHP parses)" || fail "page: $(ls -la /var/www/apps/$A 2>&1 | head -n 5)"
fi
CRON="$(grep -c "$A" /var/spool/cron/crontabs/root)"

# Its cron jobs are in WD's own list too, so they're still there when the firmware writes root's crontab afresh (every
# night)
if [ "${CRON}" -gt 0 ]; then
    REBUILT="$(xmldbc --crontab | grep -c "# $A-")"
    [ "${REBUILT}" = "${CRON}" ] && pass "its ${CRON} cron job(s) are in WD's list (kept when WD rewrites the crontab)" \
        || fail "WD's list has ${REBUILT} of its ${CRON} cron job(s): $(xmldbc --crontab)"
fi

case "${CHECK}" in
    port:*)
        port="${CHECK#port:}"
        waited=0

        until listening "$port"; do
            [ $waited -ge 120 ] && break
            sleep 2
            waited=$((waited + 2))
        done

        listening "$port" && pass "answering on port $port after ${waited}s" || { fail "not answering on port $port: $(tail -n 8 /tmp/start.log; tail -n 8 /tmp/debug_apkg 2>/dev/null)"; }
        ;;
    cmd:*)
        out="$(PATH=/usr/local/bin:/usr/bin:/bin:/opt/bin:$PATH sh -c "${CHECK#cmd:}" 2>&1)" && pass "\`${CHECK#cmd:}\` works: $(echo "$out" | head -n 1 | cut -c1-80)" || fail "\`${CHECK#cmd:}\`: $(echo "$out" | head -n 3)"
        ;;
esac

echo '== stop, clean, remove'
sh $P/$A/stop.sh $P/$A > /tmp/stop.log 2>&1

case "${CHECK}" in
    port:*)
        sleep 2
        ! listening "${CHECK#port:}" && pass "stopped (port ${CHECK#port:} closed)" || fail 'still answering after stop.sh'
        ;;
esac
sh $P/$A/clean.sh $P/$A > /tmp/clean.log 2>&1
[ ! -e /var/www/apps/$A ] && [ ! -e /var/www/$A ] && ! grep -q "$A" /var/spool/cron/crontabs/root \
    && ! xmldbc --crontab | grep -q "# $A-" \
    && pass "cleaned: its pages and its ${CRON} cron job(s) gone" || fail "clean: $(ls -d /var/www/apps/$A /var/www/$A 2>&1); $(grep "$A" /var/spool/cron/crontabs/root); $(xmldbc --crontab)"
sh $P/$A/remove.sh $P/$A > /tmp/remove.log 2>&1

if [ ! -d $P/$A ]; then
    if [ -n "${DATA_FOLDER}" ] && [ -d "$P/${DATA_FOLDER}" ]; then
        pass "removed - its data kept (Nas_Prog/${DATA_FOLDER})"
    elif [ -n "${DATA_FOLDER}" ]; then
        pass 'removed (it made no data folder here)'
    else
        pass 'removed'
    fi
else
    fail "remove: Nas_Prog/$A still there"
fi
