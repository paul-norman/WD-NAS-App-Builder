#!/bin/sh
# Runs Headlamp (a web UI for Kubernetes) as its own user, for the k3s app's cluster, with its data in the persistent
# path Nas_Prog/_headlamp - kept across reinstalls. Run by the app's scripts and its management page:
#   headlamp_ctl.sh setup     - create its user, folders and settings (where missing)
#   headlamp_ctl.sh start     - write its kubeconfig and the cluster's account for it, then start it (on port 4466)
#   headlamp_ctl.sh stop      - stop Headlamp
#   headlamp_ctl.sh restart   - stop, then start
#   headlamp_ctl.sh token     - print the account's token (what Headlamp asks for)
#   headlamp_ctl.sh new-token - replace the account's token (the old one stops working)
#   headlamp_ctl.sh daily     - the daily job: keeping its log small
#   headlamp_ctl.sh nginx     - add / update Headlamp's site in the Nginx app (and reload it)
#
# Headlamp's kubeconfig names the cluster without any credentials, so it asks whoever opens it for a token: the one of
# the headlamp-admin service account (cluster-admin), which the app adds to the cluster through k3s's own manifests
# folder (applied by k3s whenever it runs)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_headlamp"
PATH="${PATH}:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
HOME_PATH="${DATA_PATH}/home"
SETTINGS_FILE="${DATA_PATH}/settings"
KUBECONFIG_FILE="${DATA_PATH}/kubeconfig"
HEADLAMP_LOG="${DATA_PATH}/headlamp.log"
PID_FILE=/var/run/headlamp.pid
PORT=4466
# The k3s app's cluster: its certificate authority (kept with the cluster) and its manifests folder
K3S="${APPS_PATH}/k3s/binaries/k3s"
K3S_CA="${APPS_PATH}/_k3s/data/server/tls/server-ca.crt"
MANIFEST="${APPS_PATH}/_k3s/data/server/manifests/headlamp-admin.yaml"
# Its own user and group (created if missing): the IDs used when creating them
HEADLAMP_ID=94
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') headlamp/headlamp_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    local value

    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether Headlamp is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The headlamp user's ID and group ID, from the NAS's own user list.
#
# Prints them, separated by a space
headlamp_ids() {
    awk -F: '$1 == "headlamp" { print $3 " " $4 }' /etc/passwd
}

setup() {
    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^headlamp:' /etc/group || addgroup -g ${HEADLAMP_ID} headlamp
    grep -q '^headlamp:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${HEADLAMP_ID} -G headlamp headlamp

    if [ -z "$(headlamp_ids)" ]; then
        log "Could not create the headlamp user (are ID ${HEADLAMP_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(headlamp_ids)

    # Its home (the plugins you add, its settings) belongs to its user; the settings and log to root
    mkdir -p "${HOME_PATH}/plugins"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${HOME_PATH}"
    chmod 700 "${HOME_PATH}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LISTEN=all\n' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${HEADLAMP_LOG}"
    chmod 600 "${HEADLAMP_LOG}"
}

# Writes the cluster's account for Headlamp into k3s's manifests folder (k3s applies it, now or whenever it next starts):
# the headlamp-admin service account, as cluster-admin, with a long-lived token.
#
# Prints nothing; returns 1 if the k3s app's cluster isn't there
write_manifest() {
    [ -d "$(dirname "$(dirname "${MANIFEST}")")" ] || return 1
    mkdir -p "$(dirname "${MANIFEST}")"
    cat > "${MANIFEST}.tmp" <<'EOF'
# Written by the Headlamp app: the account whose token Headlamp asks for
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp-admin
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: headlamp-admin
type: kubernetes.io/service-account-token
EOF
    # Only replaced when it changed: k3s re-applies a manifest whenever its file does
    if cmp -s "${MANIFEST}.tmp" "${MANIFEST}"; then
        rm -f "${MANIFEST}.tmp"
    else
        mv -f "${MANIFEST}.tmp" "${MANIFEST}"
    fi
}

# Writes Headlamp's kubeconfig: the k3s app's cluster (on the NAS itself, with its certificate authority) without any
# credentials - so Headlamp asks for a token.
#
# Prints nothing; returns 1 if the cluster's certificate authority isn't there (k3s hasn't run yet)
write_kubeconfig() {
    local ca

    [ -s "${K3S_CA}" ] || return 1
    set -- $(headlamp_ids)
    # (PHP: the NAS's BusyBox may have no base64)
    ca="$(php -r 'echo base64_encode(file_get_contents($argv[1]));' "${K3S_CA}")"
    ( umask 077; cat > "${KUBECONFIG_FILE}.tmp" <<EOF
# Written by the Headlamp app at every start: changes here are overwritten
apiVersion: v1
kind: Config
clusters:
  - name: nas
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: ${ca}
users:
  - name: token
    user: {}
contexts:
  - name: nas
    context:
      cluster: nas
      user: token
current-context: nas
EOF
    )
    chown "$1:$2" "${KUBECONFIG_FILE}.tmp" && mv -f "${KUBECONFIG_FILE}.tmp" "${KUBECONFIG_FILE}"
}

start() {
    local host=0.0.0.0 kubeconfig=''

    if running; then
        log "Headlamp is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    write_manifest || log "the k3s app's cluster wasn't found: Headlamp has no cluster to show (install the k3s app)"

    if write_kubeconfig; then
        kubeconfig="${KUBECONFIG_FILE}"
    else
        log "k3s's certificate authority wasn't found (${K3S_CA}): start the k3s app, then restart Headlamp"
    fi

    [ "$(setting LISTEN all)" = local ] && host=127.0.0.1
    set -- $(headlamp_ids)
    log "starting Headlamp on ${host}:${PORT} (log: ${HEADLAMP_LOG})"
    cd "${HOME_PATH}" || return 1
    ( exec env HOME="${HOME_PATH}" HEADLAMP_STATIC_PLUGINS_DIR="${BIN}/static-plugins" \
        "${BIN}/headlamp_runas" "$1" "$2" "${BIN}/headlamp-server" \
        ${kubeconfig:+-kubeconfig "${kubeconfig}"} \
        -html-static-dir "${BIN}/frontend" \
        -plugins-dir "${BIN}/plugins" \
        -user-plugins-dir "${HOME_PATH}/plugins" \
        -listen-addr "${host}" \
        -port "${PORT}" \
        -log-level warn ) >> "${HEADLAMP_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Headlamp started with PID: $(cat ${PID_FILE})"
}

stop() {
    local pid waited=0

    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Headlamp (PID ${pid})"
        kill "${pid}"

        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${waited}" -ge 20 ]; then
                log 'Headlamp did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# Prints the headlamp-admin account's token (from the cluster - k3s must be running).
#
# Prints it; returns 1 if it can't be read
token() {
    local token

    token="$("${K3S}" kubectl -n kube-system get secret headlamp-admin-token -o 'jsonpath={.data.token}' 2>/dev/null)"
    [ -n "${token}" ] || return 1
    echo "${token}" | php -r 'echo base64_decode(trim(stream_get_contents(STDIN))), "\n";'
}

# Replaces the account's token, so that the old one stops working (within seconds: the API server remembers a token it
# accepted for 10 seconds). The account itself is made again: its token only changes with it (a token names the account,
# and its signature is the same each time).
#
# Prints what it did
new_token() {
    local waited=0

    "${K3S}" kubectl -n kube-system delete secret/headlamp-admin-token serviceaccount/headlamp-admin --ignore-not-found \
        --wait=true > /dev/null 2>&1 || return 1
    "${K3S}" kubectl apply -f "${MANIFEST}" > /dev/null 2>&1 || return 1

    # Kubernetes fills the new secret in a moment
    until token > /dev/null; do
        if [ "${waited}" -ge 20 ]; then
            return 1
        fi

        sleep 1
        waited=$((waited + 1))
    done

    log 'replaced the headlamp-admin token'
}

# Keeps Headlamp's log under 1MB (the previous part is kept as headlamp.log.1).
#
# Prints nothing
rotate_log() {
    if [ "$(wc -c < "${HEADLAMP_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        cp "${HEADLAMP_LOG}" "${HEADLAMP_LOG}.1" && : > "${HEADLAMP_LOG}"
        chmod 600 "${HEADLAMP_LOG}.1"
    fi
}

# The Nginx app finds Headlamp by its folder and serves it at https://headlamp.<its domain>: rewrite its sites.
#
# Prints nothing
nginx_site() {
    local nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
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
    token) token ;;
    new-token) new_token ;;
    daily) rotate_log ;;
    nginx) nginx_site ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|token|new-token|daily|nginx" >&2

        exit 1
        ;;
esac
