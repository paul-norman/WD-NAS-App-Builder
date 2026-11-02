#!/bin/sh
# Makes the app's OpenSSH the NAS's own sshd in place of WD's - and back again - underneath WD's own way of running it:
# WD's ssh_daemon (the dashboard's SSH switch, and system_init at boot) starts /usr/sbin/sshd, a link in RAM to WD's
# 8.4p1, with WD's /etc/ssh/sshd_config, its host key and its login user (sshd, with root's ID). The app points that
# link at a launcher for its own sshd, and /usr/bin/sftp-server at its own - nothing of WD's is changed. / and /etc are
# in RAM, so this is applied on every boot (start.sh):
#
#   ssh_ctl.sh setup     - its user for privilege separation, /usr/local/openssh (where its sshd finds its helpers), the
#                          launcher and the keys added on the page
#   ssh_ctl.sh swap      - switch to the app's sshd: a trial login on a spare port first (a throwaway key), then the
#                          running sshd is replaced - and WD's put back if the app's doesn't take over
#   ssh_ctl.sh restore   - switch back to WD's sshd
#   ssh_ctl.sh restart   - start the running sshd again (e.g. with new settings), falling back to WD's if it fails
#   ssh_ctl.sh keys      - copy the page's keys to where sshd reads them (no restart needed)
#   ssh_ctl.sh status    - what's running (for the page)
#
# Open sessions aren't affected by any of this: only the listener (the process that accepts new connections) restarts.

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_openssh"
BIN="${APP_PATH}/binaries"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/-[0-9]*$//')"
# The app's 10.6.1 is OpenSSH's 10.6p1 - and so is 10.6.1-1, its first packaging revision
OPENSSH_VERSION="$(echo "${VERSION}" | sed 's/\.\([0-9]*\)$/p\1/')"
# Where its sshd was built to find its helper programs (sshd-session, sshd-auth): links to the app's, made here
RUN=/usr/local/openssh
RUN_MARKER="${RUN}/.openssh-app"
WD_SSHD=/usr/local/modules/usr/sbin/sshd
WD_SFTP=/usr/local/modules/usr/bin/sftp-server
SSHD_LINK=/usr/sbin/sshd
SFTP_LINK=/usr/bin/sftp-server
CONFIG=/etc/ssh/sshd_config
# The keys added on the page (kept), and the copy sshd reads: sshd refuses key files in folders others can write to,
# which the NAS's volumes can be
KEYS="${DATA_PATH}/authorized_keys"
KEYS_RUN=/etc/ssh/authorized_keys.openssh-app
SETTINGS_FILE="${DATA_PATH}/settings"
# WD's command line for its sshd (saved from the running one), and what the app last did
ARGS_FILE=/var/run/openssh-app.args
DEFAULT_ARGS="-E /var/log/sshd.log -f ${CONFIG}"
STATE_FILE=/var/run/openssh-app.state
PID_FILE=/var/run/sshd.pid
# Its unprivileged user for privilege separation (WD's own "sshd" user is the login user, with root's ID)
PRIV_USER=sshpriv
PRIV_ID=85
TRIAL_DIR=/var/run/openssh-trial
TRIAL_PORT=22022
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') openssh/ssh_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

state() {
    printf 'SANDBOX=%s\nFALLBACK=%s\n' "${SANDBOX:-}" "$1" > "${STATE_FILE}"
}

# The running listener's PID (the process that accepts connections - not the sessions, nor the app's trial)
listener_pid() {
    pid="$(cat "${PID_FILE}" 2>/dev/null)"

    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q 'listener'; then
        echo "${pid}"

        return
    fi

    for dir in /proc/[0-9]*; do
        if tr '\0' ' ' < "${dir}/cmdline" 2>/dev/null | grep "\[listener\]" | grep -qv 'openssh-trial'; then
            echo "${dir#/proc/}"

            return
        fi
    done
}

# Which sshd a process runs: app, wd or other
sshd_of() {
    exe="$(readlink "/proc/$1/exe" 2>/dev/null)"

    case "${exe}" in
        "$(readlink -f "${BIN}/bin/sshd")") echo app ;;
        "$(readlink -f "${WD_SSHD}")") echo wd ;;
        *) echo other ;;
    esac
}

# The arguments WD started its sshd with (from its listener's title: "sshd: /usr/sbin/sshd -E ... [listener] ...")
running_args() {
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed -e 's/^sshd: [^ ]*//' -e 's/ \[listener\].*$//' -e 's/^ *//'
}

wd_args() {
    args="$(cat "${ARGS_FILE}" 2>/dev/null)"
    echo "${args:-${DEFAULT_ARGS}}"
}

# The options the app adds to sshd: the page's keys (as well as each user's own ~/.ssh/authorized_keys), the NAS itself
# spared OpenSSH's penalties (since 9.8 it refuses addresses that keep failing to log in for a while - not the NAS's own
# connections, e.g. the app's checks), and no password logins if the page says so
app_options() {
    printf '%s\n' '-o' "AuthorizedKeysFile=.ssh/authorized_keys ${KEYS_RUN}" '-o' 'PerSourcePenaltyExemptList=127.0.0.1,::1'

    if [ "$(setting PASSWORDS on)" = off ]; then
        printf '%s\n' '-o' 'PasswordAuthentication=no' '-o' 'KbdInteractiveAuthentication=no' '-o' 'PermitEmptyPasswords=no'
    fi
}

write_launcher() {
    {
        echo '#!/bin/sh'
        echo "# The NAS's sshd (started as /usr/sbin/sshd by WD's ssh_daemon): OpenSSH ${OPENSSH_VERSION} from the openssh app,"
        echo "# with the app's settings - written by ${APP_PATH}/ssh_ctl.sh"
        printf 'exec %s/bin/sshd' "${RUN}"
        app_options | while IFS= read -r option; do printf " '%s'" "${option}"; done
        echo ' "$@"'
    } > "${RUN}/sshd.tmp"
    chmod 755 "${RUN}/sshd.tmp"
    mv -f "${RUN}/sshd.tmp" "${RUN}/sshd"
}

keys() {
    umask 077

    if [ -f "${KEYS}" ]; then
        cp "${KEYS}" "${KEYS_RUN}.tmp"
    else
        : > "${KEYS_RUN}.tmp"
    fi

    chmod 600 "${KEYS_RUN}.tmp"
    mv -f "${KEYS_RUN}.tmp" "${KEYS_RUN}"
}

setup() {
    # Its user for privilege separation (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q "^${PRIV_USER}:" /etc/group || addgroup -g ${PRIV_ID} ${PRIV_USER}
    grep -q "^${PRIV_USER}:" /etc/passwd || adduser -D -H -h /var/empty -s /bin/false -u ${PRIV_ID} -G ${PRIV_USER} ${PRIV_USER}

    if [ "$(awk -F: -v u=${PRIV_USER} '$1 == u { print $3 }' /etc/passwd)" != "${PRIV_ID}" ]; then
        log "Could not create the ${PRIV_USER} user (are ID ${PRIV_ID}'s user or group already taken?)"

        return 1
    fi

    mkdir -p /var/empty
    chown root:root /var/empty
    chmod 755 /var/empty

    mkdir -p "${DATA_PATH}"
    chmod 700 "${DATA_PATH}"
    [ -f "${SETTINGS_FILE}" ] || printf 'PASSWORDS=on\n' > "${SETTINGS_FILE}"
    chmod 600 "${SETTINGS_FILE}"
    [ -f "${KEYS}" ] && chmod 600 "${KEYS}"

    if [ -e "${RUN}" ] && [ ! -f "${RUN_MARKER}" ]; then
        log "${RUN} already exists (something else uses it) - not using the app's OpenSSH"

        return 1
    fi

    rm -rf "${RUN}"
    mkdir -p "${RUN}/libexec"
    touch "${RUN_MARKER}"
    ln -s "${BIN}/bin" "${RUN}/bin"
    ln -s "${BIN}/libexec/sshd-session" "${RUN}/libexec/sshd-session"
    ln -s "${BIN}/libexec/sftp-server" "${RUN}/libexec/sftp-server"

    # Its sandbox for the pre-login program: seccomp filters if the NAS's kernel has them (sshd stops without them
    # since 10.4), otherwise the build without one (privilege separation still applies)
    if "${BIN}/bin/seccomp_check"; then
        SANDBOX=seccomp
        ln -s "${BIN}/libexec/sshd-auth" "${RUN}/libexec/sshd-auth"
    else
        SANDBOX=none
        log "the NAS's kernel has no seccomp filters: using OpenSSH without its system call sandbox"
        ln -s "${BIN}/libexec-nosandbox/sshd-auth" "${RUN}/libexec/sshd-auth"
    fi

    write_launcher
    keys
}

# Waits up to $2 seconds for a listener running sshd $1 (app or wd)
wait_listener() {
    waited=0

    while [ ${waited} -lt "$2" ]; do
        pid="$(listener_pid)"
        [ -n "${pid}" ] && [ "$(sshd_of "${pid}")" = "$1" ] && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

stop_listener() {
    pid="$(listener_pid)"
    [ -n "${pid}" ] || return 0
    kill "${pid}"
    waited=0

    while kill -0 "${pid}" 2>/dev/null && [ ${waited} -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}"

    return 0
}

# Starts sshd as WD does (through /usr/sbin/sshd, with WD's arguments): $1 = which one should be running then
start_listener() {
    # shellcheck disable=SC2046
    "${SSHD_LINK}" $(wd_args) 2>> ${LOG}
    wait_listener "$1" 10
}

links_to_app() {
    ln -sf "${RUN}/sshd" "${SSHD_LINK}"
    ln -sf "${RUN}/libexec/sftp-server" "${SFTP_LINK}"
}

links_to_wd() {
    ln -sf "${WD_SSHD}" "${SSHD_LINK}"
    ln -sf "${WD_SFTP}" "${SFTP_LINK}"
}

# The user WD's configuration lets log in (the first in its AllowUsers - WD's is sshd), for the trial. (sshd -T names
# its settings in mixed case since 10.4, lower case before)
login_user() {
    user="$("${RUN}/bin/sshd" -T -f "${CONFIG}" 2>/dev/null | awk 'tolower($1) == "allowusers" { print $2; exit }')"
    echo "${user:-root}"
}

# A trial of the app's sshd with WD's configuration, on the NAS itself only, before it replaces the running one: a login
# (a shell command and SFTP) with a throwaway key
trial() {
    rm -rf "${TRIAL_DIR}"
    mkdir -m 700 "${TRIAL_DIR}" || return 1
    "${BIN}/bin/ssh-keygen" -q -t ed25519 -N '' -C openssh-app-trial -f "${TRIAL_DIR}/key" || return 1
    port=${TRIAL_PORT}

    while awk -v p="$(printf ':%04X' ${port})" 'index($2, p) && $4 == "0A" { found = 1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; do
        port=$((port + 1))
    done

    user="$(login_user)"
    "${RUN}/bin/sshd" -f "${CONFIG}" -E "${TRIAL_DIR}/sshd.log" -o "Port=${port}" -o ListenAddress=127.0.0.1 \
        -o "PidFile=${TRIAL_DIR}/sshd.pid" -o "AuthorizedKeysFile=${TRIAL_DIR}/key.pub" -o PerSourcePenalties=no \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
    result=1
    waited=0

    while [ ! -s "${TRIAL_DIR}/sshd.pid" ] && [ ${waited} -lt 10 ]; do
        sleep 1; waited=$((waited + 1));
    done

    # -F /dev/null: none of the NAS's or root's own client settings
    options="-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=10 -o LogLevel=ERROR -i ${TRIAL_DIR}/key"

    # shellcheck disable=SC2086
    if [ "$("${BIN}/bin/ssh" ${options} -p "${port}" "${user}@127.0.0.1" 'echo trial-ok' 2>> "${TRIAL_DIR}/client.log")" = trial-ok ] \
        && echo pwd | "${BIN}/bin/sftp" ${options} -b - -P "${port}" "${user}@127.0.0.1" > /dev/null 2>> "${TRIAL_DIR}/client.log"; then
        result=0
    else
        log "The trial login to OpenSSH ${OPENSSH_VERSION} failed: $(tail -n 3 "${TRIAL_DIR}/client.log" "${TRIAL_DIR}/sshd.log" 2>/dev/null | grep -v '^==' | tr '\n' ' ')"
    fi

    pid="$(cat "${TRIAL_DIR}/sshd.pid" 2>/dev/null)"
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
    rm -rf "${TRIAL_DIR}"

    return ${result}
}

# WD's sshd back, and running if SSH was on
fall_back() {
    log "$1 - switching back to WD's sshd"
    links_to_wd

    if [ -n "${was_running}" ]; then
        stop_listener
        start_listener wd || log "WD's sshd didn't start either (see /var/log/sshd.log)"
    fi

    state "$1"

    return 1
}

swap() {
    if [ ! -x "${WD_SSHD}" ]; then
        log "WD's sshd isn't at ${WD_SSHD} - not switching (is this a WD NAS with OS5?)"

        return 1
    fi

    setup || return 1

    pid="$(listener_pid)"
    was_running="${pid}"

    # WD's command line, from its running sshd (once: the app restarts it with the same)
    if [ -n "${pid}" ] && [ "$(sshd_of "${pid}")" = wd ]; then
        running_args "${pid}" > "${ARGS_FILE}"
    fi

    if ! output="$("${RUN}/sshd" -t -f "${CONFIG}" 2>&1)"; then
        fall_back "OpenSSH ${OPENSSH_VERSION} doesn't accept the NAS's sshd_config: ${output}"

        return 1
    fi

    trial || { fall_back "OpenSSH ${OPENSSH_VERSION} failed its trial login"; return 1; }

    links_to_app

    if [ -n "${was_running}" ]; then
        stop_listener
        start_listener app || { fall_back "OpenSSH ${OPENSSH_VERSION} didn't start"; return 1; }
        log "OpenSSH ${OPENSSH_VERSION} is the NAS's sshd (sandbox: ${SANDBOX})"
    else
        log "OpenSSH ${OPENSSH_VERSION} will be the NAS's sshd when SSH is switched on in the dashboard (sandbox: ${SANDBOX})"
    fi

    state ''
}

restart() {
    [ "$(readlink "${SSHD_LINK}")" = "${RUN}/sshd" ] || { swap; return; }
    SANDBOX="$(sed -n 's/^SANDBOX=//p' "${STATE_FILE}" 2>/dev/null)"
    write_launcher
    was_running="$(listener_pid)"
    [ -n "${was_running}" ] || return 0

    if ! output="$("${RUN}/sshd" -t -f "${CONFIG}" 2>&1)"; then
        fall_back "OpenSSH ${OPENSSH_VERSION} doesn't accept the settings: ${output}"

        return 1
    fi

    stop_listener
    start_listener app || { fall_back "OpenSSH ${OPENSSH_VERSION} didn't start again"; return 1; }
    log "restarted OpenSSH ${OPENSSH_VERSION}"
}

restore() {
    if [ "$(readlink "${SSHD_LINK}")" = "${RUN}/sshd" ] || [ "$(readlink "${SFTP_LINK}")" = "${RUN}/libexec/sftp-server" ]; then
        links_to_wd
    fi

    pid="$(listener_pid)"

    if [ -n "${pid}" ] && [ "$(sshd_of "${pid}")" != wd ]; then
        stop_listener
        start_listener wd && log "switched back to WD's sshd" || log "WD's sshd didn't start (see /var/log/sshd.log)"
    fi

    [ -f "${RUN_MARKER}" ] && rm -rf "${RUN}"
    rm -f "${KEYS_RUN}" "${STATE_FILE}"
}

status() {
    pid="$(listener_pid)"
    echo "LISTENER=$([ -n "${pid}" ] && sshd_of "${pid}" || echo none)"
    echo "LINKED=$([ "$(readlink "${SSHD_LINK}")" = "${RUN}/sshd" ] && echo yes || echo no)"
    cat "${STATE_FILE}" 2>/dev/null
}

case "$1" in
    setup) setup ;;
    swap) swap ;;
    restore) restore ;;
    restart) restart ;;
    keys) keys ;;
    status) status ;;
    *)
        echo "Usage: $0 setup|swap|restore|restart|keys|status" >&2

        exit 1
        ;;
esac
