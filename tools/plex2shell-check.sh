#!/bin/sh
# Checks a WD My Cloud OS5 NAS (Intel or ARM) for Plex Media Server's "Plex2Shell" vulnerability (CVE-2026-96652,
# -96654, -96655 and -96656: unauthenticated remote code execution in Plex before 1.43.3.10861) and for signs that it
# was used against it - the miner (XMRig) and proxy ("myawesomeproxy") dropped in the wild, the exploit's traces in
# Plex's logs, and programs Plex shouldn't have started. Read-only: it changes nothing, and connects nowhere but Plex
# on the NAS itself. Run as root over SSH (the NAS's own sh - BusyBox - is enough):
#
#     sh plex2shell-check.sh
#
# Plex is found wherever it runs on the NAS: Plex's own WD package, or a Docker container (through /proc - no Docker
# commands needed), and installed but stopped. The indicators (process and file names, mining ports, log patterns) are
# those of gmolveau's check-plex2shell.sh (gist.github.com/gmolveau/b02c2e58b877cf138e2859dbfb5cc20e), made to work
# with the NAS's BusyBox tools; a check that can't run says SKIP, never PASS.
#
# Exit codes: 0 no indicators found and Plex patched; 1 action needed (vulnerable, version unknown, or an indicator);
# 2 Plex not found on the NAS; 3 nothing checked (one of the NAS's tools this script needs doesn't work)

set -u

# The first fixed Plex build
FIX_MIN=1.43.3.10861
# Known indicators: process names / command lines, file names, and the ports miners connect to
BAD_PROCESS='xmrig myawesomeproxy cryptonight stratum+tcp minerd kdevtmpfsi kinsing'
BAD_FILE='xmrig|myawesomeproxy|miner'
MINING_PORTS='3333 14444 14433 45700'
# The exploit's traces in Plex's logs: its server-side request (an external url= to the universal transcoder), and the
# junk requests and token seen with it
BAD_LOG='transcode/universal\?[^ ]*url=(https?|ftp|gopher)|GET /player/timeline\?\$|\$X-Plex-Token|myawesomeproxy'

# The NAS's own tools first: when Entware is installed, its programs come first in the PATH - and a check for an
# attack shouldn't rely on add-on programs (on the ARM models, ones built for other Linux systems can also crash on the
# NAS's kernel, which uses larger memory pages)
PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
export PATH

FAILS=0
WARNS=0
SKIPS=0
VULNERABLE=0
VERSION_UNKNOWN=0

if [ -t 1 ]; then
    ESC="$(printf '\033')"
    GREEN="${ESC}[32m" YELLOW="${ESC}[33m" RED="${ESC}[31m" BOLD="${ESC}[1m" RESET="${ESC}[0m"
else
    GREEN='' YELLOW='' RED='' BOLD='' RESET=''
fi

# The first of the tools this script relies on that doesn't work as it uses them (e.g. a grep that crashes, or that
# says it found nothing when it can't run - every check would then PASS without having looked).
#
# Prints its name, or nothing if they all work
broken_tool() {
    [ "$(printf 'Ab\nc\n' | grep -iE 'x|b' 2>/dev/null)" = Ab ] || { echo grep; return; }
    printf 'a\n' | grep -qE '^(b|c)' 2>/dev/null
    [ $? = 1 ] || { echo grep; return; }
    [ "$(printf 'a b\n' | awk '{ print $2 }' 2>/dev/null)" = b ] || { echo awk; return; }
    [ "$(printf 'a\n' | sed 's/a/b/' 2>/dev/null)" = b ] || { echo sed; return; }
    [ "$(printf 'A\0B' | tr '\0' ' ' 2>/dev/null | tr 'A-Z' 'a-z' 2>/dev/null)" = 'a b' ] || { echo tr; return; }
    [ "$(printf 'x.y\n' | cut -d . -f 2 2>/dev/null)" = y ] || { echo cut; return; }
    [ "$(printf 'b\na\n' | sort 2>/dev/null | head -n 1)" = a ] || { echo sort; return; }
    [ "$(find / -maxdepth 0 2>/dev/null)" = / ] || { echo find; return; }
    [ -n "$(readlink /proc/self/exe 2>/dev/null)" ] || { echo readlink; return; }
}

# Makes sure the tools this script relies on work: any that doesn't is replaced by BusyBox's own (when the NAS has
# BusyBox and its one works), else the script stops - nothing it found could be trusted.
use_working_tools() {
    local tool path
    local replaced=' '

    while true; do
        tool="$(broken_tool)"
        [ -n "${tool}" ] || return 0

        case "${replaced}" in
            *" ${tool} "*) ;;
            *)
                path="$(command -v "${tool}" 2>/dev/null)"

                if command -v busybox > /dev/null 2>&1; then
                    eval "${tool}() { busybox ${tool} \"\$@\"; }"
                    replaced="${replaced}${tool} "
                    continue
                fi
                ;;
        esac

        printf 'Nothing was checked: the NAS'"'"'s %s (%s) does not work - it crashed, or answered wrongly - nor\n' \
            "${tool}" "${path:-not found}" >&2
        printf 'does BusyBox'"'"'s, and every check relies on it. Is an add-on (e.g. Entware) replacing it?\n' >&2

        exit 3
    done
}

# Prints a check's result (and counts warnings and failures).
#
# $* The line
pass() {
    printf '%s[PASS]%s  %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
    printf '%s[WARN]%s  %s\n' "${YELLOW}" "${RESET}" "$*"
    WARNS=$((WARNS + 1))
}

fail() {
    printf '%s[FAIL]%s  %s\n' "${RED}" "${RESET}" "$*"
    FAILS=$((FAILS + 1))
}

skip() {
    printf '%s[SKIP]%s  %s\n' "${BOLD}" "${RESET}" "$*"
    SKIPS=$((SKIPS + 1))
}

# Prints lines indented under a result (at most 10, each cut to 200 characters).
#
# $1 text The lines
details() {
    printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 10 | cut -c 1-200 | sed 's/^/        /'
}

# Whether a version is at least another (e.g. 1.43.4.10903-e5521bd8c and 1.43.3.10861: the parts before any - compared
# number by number).
#
# $1 version The version
# $2 minimum The other
#
# Returns 0 if it is
version_at_least() {
    local a="${1%%-*}."
    local b="${2%%-*}."
    local x y i

    for i in 1 2 3 4; do
        x="$(echo "${a}" | cut -d . -f ${i} | tr -cd '0-9')"
        y="$(echo "${b}" | cut -d . -f ${i} | tr -cd '0-9')"
        [ "${x:-0}" -gt "${y:-0}" ] && return 0
        [ "${x:-0}" -lt "${y:-0}" ] && return 1
    done

    return 0
}

# A process's command line, with spaces between its arguments.
#
# $1 pid The process
#
# Prints it
cmdline() {
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

# A value from a process's status (e.g. its parent: PPid, its user: Uid).
#
# $1 pid  The process
# $2 name The value's name
#
# Prints its first field
status_of() {
    awk -v name="$2:" '$1 == name { print $2; exit }' "/proc/$1/status" 2>/dev/null
}

# Whether a process descends from another (its parents, up to the first process).
#
# $1 pid      The process
# $2 ancestor The other
#
# Returns 0 if it does
descends_from() {
    local pid="$1"
    local depth=0

    while [ -n "${pid}" ] && [ "${pid}" != 0 ] && [ "${pid}" != 1 ] && [ ${depth} -lt 50 ]; do
        pid="$(status_of "${pid}" PPid)"
        [ "${pid}" = "$2" ] && return 0
        depth=$((depth + 1))
    done

    return 1
}

# Plex's version, as Plex itself says it on the NAS (its identity, without a login).
#
# Prints it, or nothing if Plex doesn't answer on port 32400
identity_version() {
    local identity=''

    if command -v curl > /dev/null 2>&1; then
        identity="$(curl -s -m 5 http://127.0.0.1:32400/identity 2>/dev/null)"
    elif command -v wget > /dev/null 2>&1; then
        identity="$(wget -q -T 5 -O - http://127.0.0.1:32400/identity 2>/dev/null)"
    fi

    printf '%s' "${identity}" | sed -n 's/.* version="\([^"]*\)".*/\1/p' | head -n 1
}

# Plex's version from its own log (its first line names it).
#
# $1 data Its data folder (Library/Application Support/Plex Media Server)
#
# Prints it, or nothing
log_version() {
    head -n 5 "$1/Logs/Plex Media Server.log" 2>/dev/null \
        | sed -n 's/.*Plex Media Server v\([0-9][0-9.]*[-0-9a-f]*\).*/\1/p' | head -n 1
}

# ---------------------------------------------------------------------------------------------------------------------

printf '%sPlex2Shell check for WD My Cloud OS5 (CVE-2026-96652/54/55/56)%s - read-only, nothing is changed\n\n' \
    "${BOLD}" "${RESET}"

use_working_tools

if [ "$(id -u)" != 0 ]; then
    warn 'Not running as root: other users'"'"' processes, connections and files can'"'"'t all be read (run it as root)'
fi

# Plex's main processes, native or in containers: "<pid>|<its data folder, as seen from the NAS>"
INSTANCES=''

for dir in /proc/[0-9]*; do
    pid="${dir#/proc/}"
    exe="$(readlink "${dir}/exe" 2>/dev/null)"

    case "${exe}" in
        */'Plex Media Server') ;;
        *) continue ;;
    esac

    # Its data folder from its own environment (Plex's default otherwise) - a container's through its own root
    data="$(tr '\0' '\n' < "${dir}/environ" 2>/dev/null \
        | sed -n 's/^PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=//p' | head -n 1)"
    if [ -z "${data}" ]; then
        data="$(tr '\0' '\n' < "${dir}/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -n 1)"
        data="${data}/Library/Application Support"
    fi

    root=''
    [ "$(readlink "${dir}/ns/mnt" 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ] && root="${dir}/root"
    INSTANCES="${INSTANCES}${pid}|${root}${data}/Plex Media Server
"
done

# Installed but not running: Plex data folders in the NAS's app folders (Plex's WD package keeps its data there)
STOPPED=''

if [ -z "${INSTANCES}" ]; then
    STOPPED="$(find /mnt/HD/HD_*/Nas_Prog -maxdepth 8 -type f -name Preferences.xml -path '*/Plex Media Server/*' \
        2>/dev/null | sed 's#/Preferences.xml$##')"
fi

if [ -z "${INSTANCES}" ] && [ -z "${STOPPED}" ]; then
    printf '%sPlex Media Server not found on this NAS%s (not running, and no Plex data in Nas_Prog).\n' \
        "${RED}" "${RESET}"

    exit 2
fi

# ---------------------------------------------------------------------------------------------------------------------
# Each Plex: its version, its logs, its codecs folder, and what it has started

check_data() {
    local data="$1"
    local logs codecs

    # The exploit's traces in its logs (the current one and its rotated ones)
    if [ -d "${data}/Logs" ]; then
        logs="$(grep -ahE "${BAD_LOG}" "${data}/Logs"/Plex\ Media\ Server*.log 2>/dev/null | tail -n 10)"

        if [ -n "${logs}" ]; then
            fail 'The exploit'"'"'s traces in Plex'"'"'s logs:'
            details "${logs}"
        else
            logs="$(ls "${data}/Logs"/Plex\ Media\ Server*.log 2>/dev/null | wc -l)"
            pass "No exploit traces in Plex's logs (${logs} files)"
        fi
    else
        skip "Plex's logs not found (${data}/Logs)"
    fi

    # Libraries or scripts in its codecs folder that aren't Plex's own codecs (the attack drops a library there)
    if [ -d "${data}/Codecs" ]; then
        codecs="$(find "${data}/Codecs" -type f \( -name '*.so' -o -name '*.sh' \) 2>/dev/null \
            | grep -avE '/lib[a-z0-9_]*_(encoder|decoder)\.so$')"

        if [ -n "${codecs}" ]; then
            warn 'Files in Plex'"'"'s Codecs folder that aren'"'"'t its usual codecs - check them (the attack drops' \
                'a library there):'
            details "${codecs}"
        else
            pass 'Only Plex'"'"'s own codecs in its Codecs folder'
        fi
    else
        pass 'No Codecs folder (nothing dropped there)'
    fi
}

identity="$(identity_version)"

while IFS='|' read -r pid data; do
    [ -n "${pid}" ] || continue
    exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)"
    uid="$(status_of "${pid}" Uid)"
    where='Plex'"'"'s WD package (native)'
    [ "$(readlink "/proc/${pid}/ns/mnt" 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ] \
        && where='a container (e.g. Docker)'

    printf '\n%s--- Plex Media Server, PID %s, in %s ---%s\n' "${BOLD}" "${pid}" "${where}" "${RESET}"

    # Its version: its own log's (this one's), else its identity on port 32400
    version="$(log_version "${data}")"
    [ -n "${version}" ] || version="${identity}"

    if [ -z "${version}" ]; then
        warn 'Its version is unknown: check it in Plex (Settings, General) - it must be 1.43.3.10861 or newer'
        VERSION_UNKNOWN=1
    elif version_at_least "${version}" "${FIX_MIN}"; then
        pass "Plex ${version}: patched (${FIX_MIN} or newer)"
    else
        fail "Plex ${version} is VULNERABLE (older than ${FIX_MIN}): exploited in the wild - update it now"
        VULNERABLE=1
    fi

    if [ "${uid}" = 0 ]; then
        warn 'Plex runs as root: whoever exploits it controls the whole NAS (keep it updated, and Remote Access off' \
            'unless needed)'
    fi

    # Programs it started that aren't its own (its transcoder, plug-in host, tuner... live in its own folder)
    own="${exe%/*}"
    strangers=''

    for dir in /proc/[0-9]*; do
        child="${dir#/proc/}"
        [ "${child}" = "${pid}" ] && continue
        descends_from "${child}" "${pid}" || continue
        # (not one that has already ended: a zombie, waiting for Plex to collect it)
        [ "$(status_of "${child}" State)" = Z ] && continue
        child_exe="$(readlink "${dir}/exe" 2>/dev/null)"

        case "${child_exe}" in
            "${own}"/*) ;;
            *) strangers="${strangers}PID ${child}: ${child_exe:-?} - $(cmdline "${child}")
" ;;
        esac
    done

    if [ -n "${strangers}" ]; then
        case "${strangers}" in
            *'/tmp/'*|*'/var/tmp/'*|*'/dev/shm/'*|*'(deleted)'*)
                fail 'Plex has started programs from a temporary folder (or deleted since) - a payload:'
                ;;
            *) warn 'Plex has started programs that aren'"'"'t its own - check them:' ;;
        esac

        details "${strangers}"
    else
        pass 'Plex has started only its own programs'
    fi

    check_data "${data}"
done <<EOF
${INSTANCES}
EOF

if [ -n "${STOPPED}" ]; then
    while read -r data; do
        [ -n "${data}" ] || continue
        printf '\n%s--- Plex Media Server, not running: %s ---%s\n' "${BOLD}" "${data}" "${RESET}"
        version="$(log_version "${data}")"

        if [ -z "${version}" ]; then
            warn 'Its version is unknown (it isn'"'"'t running): it must be 1.43.3.10861 or newer'
            VERSION_UNKNOWN=1
        elif version_at_least "${version}" "${FIX_MIN}"; then
            pass "Plex ${version} (when it last ran): patched"
        else
            fail "Plex ${version} (when it last ran) is VULNERABLE: update it before starting it again"
            VULNERABLE=1
        fi

        check_data "${data}"
    done <<EOF
${STOPPED}
EOF
fi

# ---------------------------------------------------------------------------------------------------------------------
# The whole NAS: miners and proxies, their connections, their files, and ways back in

printf '\n%s--- The NAS ---%s\n' "${BOLD}" "${RESET}"

# Processes known from the attacks (by name or command line), or running from a temporary folder
found=''

for dir in /proc/[0-9]*; do
    pid="${dir#/proc/}"
    [ "${pid}" = $$ ] && continue
    exe="$(readlink "${dir}/exe" 2>/dev/null)"
    line="$(cmdline "${pid}")"
    # (its program and command line in lower case, for the names - matched by the shell itself)
    text="$(printf '%s %s' "${exe}" "${line}" | tr 'A-Z' 'a-z')"
    bad=''

    for word in ${BAD_PROCESS}; do
        case "${text}" in
            *"${word}"*) bad=1 ;;
        esac
    done

    case "${exe}" in
        /tmp/*|/var/tmp/*|/dev/shm/*) bad=1 ;;
    esac

    if [ -n "${bad}" ]; then
        found="${found}PID ${pid}: ${exe:-?} - ${line}
"
    fi
done

if [ -n "${found}" ]; then
    fail 'Miner / proxy processes, or programs running from a temporary folder:'
    details "${found}"
else
    pass 'No miner or proxy processes, nothing running from a temporary folder'
fi

# Established connections to the ports miners use (/proc/net/tcp: remote address:port in hex, state 01 = established)
if [ -r /proc/net/tcp ]; then
    ports=''

    for port in ${MINING_PORTS}; do
        ports="${ports} $(printf '%04X' "${port}")"
    done

    sockets="$(awk -v ports="${ports}" '
        function hex(h,    i, n) {
            n = 0
            for (i = 1; i <= length(h); i++) n = n * 16 + index("0123456789ABCDEF", substr(h, i, 1)) - 1
            return n
        }
        BEGIN { n = split(ports, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
        NR > 1 && $4 == "01" {
            split($3, r, ":")
            if (!(r[2] in want)) next
            a = r[1]
            # (an IPv4 address, or one in IPv6 form: its last 8 digits, in the kernel'"'"'s byte order)
            if (length(a) == 32) a = substr(a, 25, 8)
            ip = hex(substr(a, 7, 2)) "." hex(substr(a, 5, 2)) "." hex(substr(a, 3, 2)) "." hex(substr(a, 1, 2))
            print $10 " " ip ":" hex(r[2])
        }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"

    if [ -n "${sockets}" ]; then
        found=''

        # Each one's process (the one holding its socket)
        for inode in $(printf '%s\n' "${sockets}" | cut -d ' ' -f 1); do
            owner=''

            for fd in /proc/[0-9]*/fd/*; do
                [ "$(readlink "${fd}" 2>/dev/null)" = "socket:[${inode}]" ] || continue
                owner="${fd#/proc/}"
                owner="${owner%%/*}"
                break
            done
            remote="$(printf '%s\n' "${sockets}" | grep "^${inode} " | cut -d ' ' -f 2)"
            found="${found}${remote} - PID ${owner:-?}: $(cmdline "${owner:-0}")
"
        done

        fail 'Connections to ports miners use (remote address:port, and the program):'
        details "${found}"
    else
        pass "No connections to the ports miners use (${MINING_PORTS})"
    fi
else
    skip 'Can'"'"'t read the NAS'"'"'s connections (/proc/net/tcp)'
fi

# Files named after the attacks' tools in the temporary folders
files="$(find /tmp /var/tmp /dev/shm -maxdepth 3 2>/dev/null | grep -iE "${BAD_FILE}")"

if [ -n "${files}" ]; then
    fail 'Miner / proxy files in a temporary folder:'
    details "${files}"
else
    pass 'No miner or proxy files in /tmp or /var/tmp'
fi

# Ways back in: cron jobs that download or run from /tmp, and SSH keys added lately
crons="$(grep -shE 'curl|wget|/tmp/' /var/spool/cron/crontabs/* /etc/crontabs/* 2>/dev/null | sort -u)"

if [ -n "${crons}" ]; then
    warn 'Cron jobs that download something or run from /tmp - check that they'"'"'re yours (or your apps'"'"'):'
    details "${crons}"
else
    pass 'No cron jobs that download something or run from /tmp'
fi

keys="$(find /home/root/.ssh /root/.ssh /home/*/.ssh -name authorized_keys -mtime -30 2>/dev/null | sort -u)"

if [ -n "${keys}" ]; then
    warn 'SSH keys changed in the last 30 days - check that it was you:'
    details "${keys}"
else
    pass 'No SSH keys changed in the last 30 days'
fi

# ---------------------------------------------------------------------------------------------------------------------

printf '\n%s================================ result ================================%s\n' "${BOLD}" "${RESET}"

if [ ${VULNERABLE} = 1 ]; then
    printf '%sFAIL: Plex is VULNERABLE to Plex2Shell - update it now (1.43.3.10861 or newer).%s\n' "${RED}" "${RESET}"
elif [ ${FAILS} -gt 0 ]; then
    printf '%sFAIL: %s sign(s) of compromise - see the FAIL lines.%s Disconnect the NAS from the network first,\n' \
        "${RED}" "${FAILS}" "${RESET}"
    echo '      and keep the evidence (don'"'"'t delete anything yet).'
elif [ ${VERSION_UNKNOWN} = 1 ]; then
    printf '%sUNKNOWN: Plex'"'"'s version couldn'"'"'t be read - check it in Plex (Settings, General).%s\n' \
        "${YELLOW}" "${RESET}"
elif [ ${WARNS} -gt 0 ]; then
    printf '%sPASS, with %s thing(s) to look at - see the WARN lines.%s\n' "${YELLOW}" "${WARNS}" "${RESET}"
else
    printf '%sPASS: Plex is patched, and no signs of compromise were found.%s\n' "${GREEN}" "${RESET}"
fi

[ ${SKIPS} -gt 0 ] && echo "(${SKIPS} check(s) couldn't run: see the SKIP lines)"
echo
echo 'If anything is wrong:'
echo '  1. Update Plex to 1.43.3.10861 or newer (from Plex'"'"'s downloads, for the NAS'"'"'s model)'
echo '  2. Turn off Plex'"'"'s Remote Access (Settings, Remote Access) unless you need it'
echo '  3. Change your plex.tv password, and sign out all devices (plex.tv, Account, Devices)'
echo '  4. If a FAIL line fired: disconnect the NAS, keep the evidence, and reinstall Plex with fresh data'

if [ ${VULNERABLE} = 1 ] || [ ${FAILS} -gt 0 ] || [ ${VERSION_UNKNOWN} = 1 ]; then
    exit 1
fi

exit 0
