#!/bin/sh
# Makes Python 3.14 the NAS's python3 (and adds pip3, pydoc3, uv and uvx), in place of WD's Python 3.9 - and back again.
# / is in RAM, so this is applied on every boot (start.sh) and nothing outlives a reboot without it. WD's own files are
# never changed: only the /usr/bin links.
#
#   python_swap.sh swap      - switch to Python 3.14 (and remember the choice)
#   python_swap.sh restore   - switch back to WD's Python 3.9 (and remember the choice, unless "restore stop")
#   python_swap.sh start     - apply the remembered choice (Python 3.14 unless switched back on the management page)
#   python_swap.sh status    - which Python is in use
#
# WD's boot scripts and wsdd (Windows network discovery) start before the apps, so they always run on WD's Python 3.9;
# only what runs later uses Python 3.14 (WD's scripts were checked: they use the standard library only, nothing removed
# since 3.9). There's no /usr/bin/python: WD's old Python 2 scripts ask for it, and must keep failing to start.

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_python"
BIN="${APP_PATH}/binaries/python/bin"
CHOICE_FILE="${DATA_PATH}/use"
WD_PYTHON=/usr/local/modules/python39/bin/python3.9
# The links made: /usr/bin/<name> -> the app's <name>
LINKS='python3 python3.14 pip3 pip3.14 pydoc3 uv uvx'
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') python/python_swap.sh $*" >> ${LOG}
    echo "$*"
}

swap() {
    if ! "${BIN}/python3" -c 'import ssl, sqlite3, venv' > /dev/null 2>&1; then
        log "Not switching to Python 3.14: it doesn't run on this NAS"

        return 1
    fi

    for name in ${LINKS}; do
        # Only where there's nothing else already, apart from WD's python3
        target="$(readlink "/usr/bin/${name}" 2>/dev/null)"

        if [ ! -e "/usr/bin/${name}" ] || [ "${name}" = python3 ] || [ "${target#"${APP_PATH}"/}" != "${target}" ]; then
            ln -sf "${BIN}/${name}" "/usr/bin/${name}"
        fi
    done

    mkdir -p "${DATA_PATH}"
    echo app > "${CHOICE_FILE}"
    log 'Switched python3 to Python 3.14'
}

restore() {
    if [ -x "${WD_PYTHON}" ]; then
        ln -sf "${WD_PYTHON}" /usr/bin/python3
    fi

    for name in ${LINKS}; do
        target="$(readlink "/usr/bin/${name}" 2>/dev/null)"

        if [ "${name}" != python3 ] && [ "${target#"${APP_PATH}"/}" != "${target}" ]; then
            rm -f "/usr/bin/${name}"
        fi
    done

    # The app being stopped isn't a choice: it switches to Python 3.14 again when started
    if [ "$1" != stop ]; then
        mkdir -p "${DATA_PATH}"
        echo wd > "${CHOICE_FILE}"
    fi

    log "Switched python3 back to WD's Python 3.9"
}

start() {
    if [ "$(cat "${CHOICE_FILE}" 2>/dev/null)" = wd ]; then
        log "python3 stays WD's Python 3.9 (as chosen on the management page)"

        return 0
    fi

    swap
}

status() {
    echo "python3: $(readlink -f /usr/bin/python3) ($(/usr/bin/python3 --version 2>&1))"
    echo "Choice: $(cat "${CHOICE_FILE}" 2>/dev/null || echo app)"
}

case "$1" in
    swap) swap ;;
    restore) restore "$2" ;;
    start) start ;;
    status) status ;;
    *) echo "Usage: $0 swap | restore [stop] | start | status"; exit 1 ;;
esac
