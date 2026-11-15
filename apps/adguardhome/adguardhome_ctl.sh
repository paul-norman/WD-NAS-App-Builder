#!/bin/sh
# Runs AdGuard Home (a DNS server that blocks ads and trackers for the whole network) as its own user, with its data in
# the persistent path Nas_Prog/_adguardhome - kept across reinstalls:
#   adguardhome_ctl.sh setup        - create its user, folders, settings and admin password (where missing)
#   adguardhome_ctl.sh start        - start it (DNS on port 53, its web interface on 8094), checking that it answers
#   adguardhome_ctl.sh stop         - stop it (and stop forwarding the network's DNS to it)
#   adguardhome_ctl.sh restart      - stop, then start
#   adguardhome_ctl.sh firewall     - bring the DNS forwarding up to date with the NAS's addresses (every 5 minutes)
#   adguardhome_ctl.sh new-password - give the admin account a new password (signing everyone out)
#   adguardhome_ctl.sh backup       - back up its settings (block lists, rules, clients, rewrites...)
#   adguardhome_ctl.sh daily        - the daily job: a backup, and keeping its log small
#   adguardhome_ctl.sh nginx        - rewrite the Nginx app's sites (its own comes from its nginx.json), and reload it
#
# It never runs as root: DNS is port 53, which only root may open, so AdGuard Home answers on port 5335 and the NAS's
# firewall forwards port 53 to it (its own NAT chain, for each of the NAS's addresses - the WD kernel has DNAT, not
# REDIRECT). Nobody else can claim it: the app writes its settings with the admin account before its first start, so
# its setup wizard never runs

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_adguardhome"
# The NAS's PHP finds the Nginx app's site: wherever it is, also with a minimal PATH (e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin:/usr/sbin:/sbin"
BIN="${APP_PATH}/binaries"
LIB="${APP_PATH}/lib/adguardhome.php"
# AdGuard Home's own folder (its settings file and data: statistics, query log, block lists - its user's only)
AGH_WORK="${DATA_PATH}/work"
CONFIG="${AGH_WORK}/AdGuardHome.yaml"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
AGH_LOG="${DATA_PATH}/adguardhome.log"
# Why it isn't running, when it refused to start (the page shows it)
PROBLEM_FILE="${DATA_PATH}/problem"
PID_FILE=/var/run/adguardhome.pid
WEB_PORT=8094
DNS_PORT=5335
# Its own NAT chain (so that its rules are removed in one go, and never mixed up with Docker's or WireGuard's)
CHAIN=ADGUARDHOME
# Its own user and group (created if missing): the IDs used when creating them
AGH_ID=57
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') adguardhome/adguardhome_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"

    echo "${value:-$2}"
}

# Whether AdGuard Home is running (its PID file's process: a number, written since the NAS started).
#
# Returns 0 if it is
running() {
    local pid="$(cat "${PID_FILE}" 2>/dev/null)"

    case "${pid}" in
        '' | *[!0-9]*) return 1 ;;
    esac

    kill -0 "${pid}" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list.
#
# Prints them (e.g. 57 57), or nothing if there's no such user
agh_ids() {
    awk -F: '$1 == "adguardhome" { print $3 " " $4 }' /etc/passwd
}

# Writes a secret (letters and digits) to a file only root can read.
#
# $1 file   The file
# $2 length The number of characters
#
# Prints nothing; returns 0 once written
new_secret() {
    ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$2" > "$1.tmp" ) && mv -f "$1.tmp" "$1"
}

# Creates its user (the NAS's user list is in RAM, so this is redone at every boot), its folders, its settings, the
# admin password and - the first time - AdGuard Home's own settings file, with the admin account.
#
# Prints what it did; returns 0 once done
setup() {
    grep -q '^adguardhome:' /etc/group || addgroup -g ${AGH_ID} adguardhome
    grep -q '^adguardhome:' /etc/passwd \
        || adduser -D -H -h /nonexistent -s /bin/false -u ${AGH_ID} -G adguardhome adguardhome

    if [ -z "$(agh_ids)" ]; then
        log "Could not create the adguardhome user (are ID ${AGH_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(agh_ids)

    # Its own folder belongs to its user (AdGuard Home rewrites its settings file when they change); the app's
    # settings and the password to root
    mkdir -p "${AGH_WORK}"
    chown root:root "${DATA_PATH}"
    chmod 711 "${DATA_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        # Its web interface only through the Nginx app - HTTPS - when it's installed
        local listen=all

        [ -d "${APPS_PATH}/nginx" ] && listen=local
        log "creating the default settings: ${SETTINGS_FILE} (LISTEN=${listen})"
        printf 'LISTEN=%s\nBACKUP_KEEP=14\n' "${listen}" > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    [ -s "${PASSWORD_FILE}" ] || new_secret "${PASSWORD_FILE}" 20
    chmod 600 "${PASSWORD_FILE}"

    if [ ! -f "${CONFIG}" ]; then
        log "writing AdGuard Home's first settings, with its admin account: ${CONFIG}"
        php "${LIB}" new-config "${CONFIG}" "${PASSWORD_FILE}" || return 1
    fi

    chown -R "$1:$2" "${AGH_WORK}"
    chmod 700 "${AGH_WORK}"
    touch "${AGH_LOG}"
    chmod 600 "${AGH_LOG}"
}

# Whether something already answers on port 53 (e.g. the Pi-hole recipe, or another DNS server): AdGuard Home would
# take its traffic away.
#
# Prints what it is, if it can tell; returns 0 if something does
port_53_taken() {
    # (port 53 = 0035; TCP's listening state is 0A, UDP's sockets have none)
    awk 'NR > 1 && $2 ~ /:0035$/ && ($4 == "0A" || FILENAME ~ /udp/) { found = 1 } END { exit !found }' \
        /proc/net/tcp /proc/net/udp /proc/net/tcp6 /proc/net/udp6 2>/dev/null
}

# Loads WD's NAT modules (as the Docker and WireGuard apps do) and links iptables' extensions, where needed.
#
# Prints nothing; returns 0
nat_modules() {
    local module

    for module in x_tables ip_tables nf_conntrack nf_defrag_ipv4 nf_conntrack_ipv4 nf_nat nf_nat_ipv4 iptable_nat \
        xt_tcpudp xt_nat; do
        if ! grep -q "^${module} " /proc/modules 2>/dev/null && [ -f "/usr/local/modules/driver/${module}.ko" ]; then
            insmod "/usr/local/modules/driver/${module}.ko" 2>/dev/null
        fi
    done

    if [ ! -e /usr/lib/xtables ] && [ -d /usr/local/modules/usrlib/xtables ]; then
        ln -s /usr/local/modules/usrlib/xtables /usr/lib/xtables
    fi

    return 0
}

# The NAS's own IPv4 addresses (not the loopback's).
#
# Prints them, one a line
nas_addresses() {
    ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); if (a[1] !~ /^127\./) print a[1] }' | sort -u
}

# The rules that should be in its chain: port 53 (UDP and TCP) to each of the NAS's addresses, forwarded to AdGuard
# Home's port on the same address.
#
# Prints them, as iptables' -S lists them
wanted_rules() {
    local address proto

    for address in $(nas_addresses); do
        for proto in udp tcp; do
            printf -- '-A %s -d %s/32 -p %s -m %s --dport 53 -j DNAT --to-destination %s:%s\n' "${CHAIN}" "${address}" \
                "${proto}" "${proto}" "${address}" "${DNS_PORT}"
        done
    done
}

# Forwards the network's DNS (port 53) to AdGuard Home: its own NAT chain, from PREROUTING (other devices) and OUTPUT
# (the NAS itself, and its containers' traffic to the NAS) - rebuilt only when the NAS's addresses changed.
#
# Prints what it did; returns 0 once in place
firewall_on() {
    local rules="$(wanted_rules)"
    local hook rule

    nat_modules
    iptables -t nat -N "${CHAIN}" 2>/dev/null

    if [ "$(iptables -t nat -S "${CHAIN}" 2>/dev/null | grep -v "^-N ")" != "${rules}" ]; then
        iptables -t nat -F "${CHAIN}" || return 1
        echo "${rules}" | while read -r rule; do
            [ -n "${rule}" ] && iptables -t nat ${rule}
        done
        log "forwarding DNS (port 53) to AdGuard Home on: $(nas_addresses | tr '\n' ' ')"
    fi

    for hook in PREROUTING OUTPUT; do
        if ! iptables -t nat -C "${hook}" -j "${CHAIN}" 2>/dev/null; then
            iptables -t nat -I "${hook}" 1 -j "${CHAIN}" || return 1
        fi
    done
}

# Stops forwarding the network's DNS to AdGuard Home: its chain, and the jumps to it, removed.
#
# Prints nothing; returns 0
firewall_off() {
    local hook

    for hook in PREROUTING OUTPUT; do
        while iptables -t nat -D "${hook}" -j "${CHAIN}" 2>/dev/null; do
            :
        done
    done

    iptables -t nat -F "${CHAIN}" 2>/dev/null
    iptables -t nat -X "${CHAIN}" 2>/dev/null

    return 0
}

# Waits (up to 60 seconds) for its web interface to answer, while it's still running.
#
# Returns 0 once it answers
wait_up() {
    local waited=0
    local code

    while [ ${waited} -lt 60 ]; do
        running || return 1
        # (its API, which asks for a login: 401)
        code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/control/status" 2>/dev/null)"

        case "${code}" in
            200 | 401) return 0 ;;
        esac

        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

# Starts it as its own user - its web interface on the NAS itself or on every address - and forwards the network's DNS
# to it. Refused if something else answers on port 53.
#
# Prints what it did; returns 0 once it answers
start() {
    local host=127.0.0.1

    if running; then
        log "AdGuard Home is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    rm -f "${PROBLEM_FILE}"

    if port_53_taken; then
        echo 'Something else already answers DNS on port 53 (e.g. the Pi-hole recipe): stop it first' \
            > "${PROBLEM_FILE}"
        log "AdGuard Home not started: $(cat "${PROBLEM_FILE}")"

        return 1
    fi

    [ "$(setting LISTEN local)" = all ] && host=0.0.0.0

    if ! php "${LIB}" set-web "${CONFIG}" "${host}"; then
        log "Could not set its web interface's address in ${CONFIG}"

        return 1
    fi

    set -- $(agh_ids)
    log "starting AdGuard Home: DNS on port 53 (${DNS_PORT}), its web interface on ${host}:${WEB_PORT}" \
        "(log: ${AGH_LOG})"
    ( cd "${AGH_WORK}" && exec env HOME="${AGH_WORK}" "${BIN}/adguardhome_runas" "$1" "$2" "${BIN}/AdGuardHome" \
        -c "${CONFIG}" -w "${AGH_WORK}" --no-check-update ) >> "${AGH_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"

    if ! wait_up; then
        log "AdGuard Home did not start (see ${AGH_LOG}): $(tail -n 3 "${AGH_LOG}" 2>/dev/null | tr '\n' ' ')"

        return 1
    fi

    if ! firewall_on; then
        echo 'Could not forward DNS (port 53) to it: the NAS'"'"'s firewall refused' > "${PROBLEM_FILE}"
        log "${PROBLEM_FILE}: $(cat "${PROBLEM_FILE}")"

        return 1
    fi

    log "AdGuard Home started with PID: $(cat ${PID_FILE})"
}

# Stops it (politely first, then - after 20 seconds - by force), and stops forwarding the network's DNS to it.
#
# Prints what it did; returns 0 once stopped
stop() {
    local pid
    local waited=0

    firewall_off

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping AdGuard Home (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'AdGuard Home did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Brings the DNS forwarding up to date with the NAS's addresses (e.g. a new one from the router), while it runs.
#
# Prints what it did; returns 0
firewall() {
    running && firewall_on

    return 0
}

# Gives the admin account a new password (letters and digits) in AdGuard Home's settings file - with AdGuard Home
# stopped meanwhile (it rewrites the file), and its sign-ins removed (everyone signs in again).
#
# Prints what it did; returns 0 once set
new_password() {
    local was_running=0
    local new="${PASSWORD_FILE}.new"

    running && was_running=1
    [ ${was_running} = 1 ] && stop
    new_secret "${new}" 20

    if ! php "${LIB}" set-password "${CONFIG}" "${new}"; then
        rm -f "${new}"
        log 'Could not set a new admin password (its settings file has no admin account any more?)'
        [ ${was_running} = 1 ] && start

        return 1
    fi

    mv -f "${new}" "${PASSWORD_FILE}"
    rm -f "${AGH_WORK}/data/sessions.db"
    log 'set a new admin password'
    [ ${was_running} = 1 ] && start

    return 0
}

# Backs up its settings file (block lists, rules, clients, rewrites, upstream servers...: its statistics and query log
# aren't kept), as one .tar.gz in Nas_Prog/_adguardhome/backups - root's only - keeping the newest ones.
#
# Prints what it did; returns 0 once written
backup() {
    local dir="${DATA_PATH}/backups"
    local keep="$(setting BACKUP_KEEP 14)"
    local file="${dir}/adguardhome-$(date '+%Y%m%d-%H%M%S').tar.gz"
    local item

    if [ ! -f "${CONFIG}" ]; then
        log 'Nothing to back up yet (no settings file)'

        return 1
    fi

    mkdir -p "${dir}" && chmod 700 "${dir}" || return 1

    if ! ( umask 077; tar -czf "${file}.tmp" -C "${AGH_WORK}" AdGuardHome.yaml ) \
        || ! mv -f "${file}.tmp" "${file}"; then
        log "Could not write the backup: ${file}"
        rm -f "${file}.tmp"

        return 1
    fi

    chmod 600 "${file}"
    log "backed up to: ${file}"

    # Keep only the newest backups
    ls -1 "${dir}"/adguardhome-*.tar.gz 2>/dev/null | sort -r | awk -v keep="${keep}" 'NR > keep' \
        | while read -r item; do
            rm -f "${item}"
        done
}

# Keeps its log under 1MB (the previous part is kept as adguardhome.log.1).
#
# Prints nothing; returns 0
rotate_log() {
    if [ "$(wc -c < "${AGH_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${AGH_LOG}" "${AGH_LOG}.1" && : > "${AGH_LOG}"
        chmod 600 "${AGH_LOG}.1"
    fi

    return 0
}

# The Nginx app finds AdGuard Home by its folder (its nginx.json) and serves it at https://adguard.<its domain>:
# rewrite its sites, and reload it.
#
# Prints nothing; returns 0 (with or without the Nginx app)
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" \
            && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart)
        stop
        start
        ;;
    firewall) firewall ;;
    new-password) new_password ;;
    backup) backup ;;
    daily)
        backup
        rotate_log
        ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|firewall|new-password|backup|daily|nginx" >&2

        exit 1
        ;;
esac
