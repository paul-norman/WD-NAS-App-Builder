#!/bin/sh
# Runs the Tasks app's tasks - scripts set up on its page, run as root - and keeps their cron jobs in step with them.
# Its data is in the persistent path (Nas_Prog/_tasks - kept across reinstalls): tasks.json, scripts/<id>.sh, each
# task's last run in status/<id>.json and status/<id>.log, and every run in history.log:
#   tasks_ctl.sh setup             - create its folders, and the example tasks on a first install
#   tasks_ctl.sh start             - schedule its tasks, then run the boot tasks (in the background, once per boot)
#   tasks_ctl.sh stop              - run the shutdown tasks if the NAS is shutting down, then unschedule its tasks
#   tasks_ctl.sh schedule          - bring cron in step with its scheduled tasks (after a change on its page)
#   tasks_ctl.sh unschedule        - take all its tasks (and its own daily job) out of cron
#   tasks_ctl.sh run <id> [reason] - run a task now (reason: manual, schedule, boot or shutdown)
#   tasks_ctl.sh kill <id>         - stop a task that's running
#   tasks_ctl.sh boot              - run the boot tasks, one after another
#   tasks_ctl.sh daily             - keep its logs small

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_tasks"
LIB="${APP_PATH}/lib/tasks.php"
STATUS_PATH="${DATA_PATH}/status"
HISTORY="${DATA_PATH}/history.log"
CRON_TAGS="${DATA_PATH}/cron_tags"
ACTIVE=/var/run/tasks.active
BOOTED=/var/run/tasks.booted
# Set once the shutdown tasks have run: WD's shutdown can stop the app more than once (seen on a PR4100)
SHUT_DOWN=/var/run/tasks.shutdown
LOG=/tmp/debug_apkg
# A task's last run's output is kept up to this size (its end)
OUTPUT_BYTES=262144
# Seconds in a minute of a task's time limit (the tests make it shorter)
MINUTE="${TASKS_TEST_MINUTE:-60}"
# Entware's tools first (as an SSH login has them), then the caller's PATH, then the NAS's own folders (cron's PATH is
# short)
export PATH="/opt/bin:/opt/sbin:${PATH}:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') tasks/tasks_ctl.sh $*" >> "${LOG}"
    echo "$*"
}

# Runs the app's PHP library with the NAS's PHP.
#
# $@ Its command and arguments (see lib/tasks.php)
#
# Prints what it prints; returns its exit code
lib() {
    php "${LIB}" "$@"
}

# Creates its folders (root's only: the scripts run as root, and their output may hold secrets) and, on a first
# install, the example tasks (switched off).
#
# Prints nothing; returns 0
setup() {
    mkdir -p "${DATA_PATH}/scripts" "${STATUS_PATH}"
    chown root:root "${DATA_PATH}"
    chmod 700 "${DATA_PATH}"
    lib seed "${DATA_PATH}" "${APP_PATH}/examples"
    touch "${HISTORY}"
    chmod 600 "${HISTORY}"

    return 0
}

# Brings cron in step with the switched-on scheduled tasks (and adds its own daily job): cron_add and cron_remove (from
# the shared helpers.sh) keep them in root's crontab and in WD's own list, which the firmware rewrites the crontab from.
#
# Prints nothing; returns 0
schedule() {
    local wanted=''
    local id
    local when
    local tag

    # The shared helpers, as an app script loads them (they need the app's folder)
    . "${APP_PATH}/helpers.sh" "${APP_PATH}/tasks_ctl.sh" "${APP_PATH}"

    while IFS="$(printf '\t')" read -r id when; do
        [ -n "${id}" ] || continue
        cron_add "${when}" "sh ${APP_PATH}/tasks_ctl.sh run ${id} schedule > /dev/null 2>&1" "tasks-${id}"
        wanted="${wanted} tasks-${id}"
    done <<EOF
$(lib cron "${DATA_PATH}")
EOF

    cron_add '20 4 * * *' "sh ${APP_PATH}/tasks_ctl.sh daily > /dev/null 2>&1" 'tasks-daily'

    # Those no longer wanted (removed, switched off or no longer scheduled)
    for tag in $(cat "${CRON_TAGS}" 2>/dev/null); do
        case " ${wanted} " in
            *" ${tag} "*) ;;
            *) cron_remove "${tag}" ;;
        esac
    done

    echo "${wanted}" | tr ' ' '\n' | grep . > "${CRON_TAGS}"

    return 0
}

# Takes all its tasks, and its own daily job, out of cron.
#
# Prints nothing; returns 0
unschedule() {
    . "${APP_PATH}/helpers.sh" "${APP_PATH}/tasks_ctl.sh" "${APP_PATH}"
    cron_remove $(cat "${CRON_TAGS}" 2>/dev/null) tasks-daily
    : > "${CRON_TAGS}"

    return 0
}

# Writes a task's last run (status/<id>.json).
#
# $1 id       The task's ID
# $2 state    running, ok, failed or timeout
# $3 reason   Why it ran: manual, schedule, boot or shutdown
# $4 started  When it started (seconds since 1970)
# $5 finished When it finished (0 while running)
# $6 code     Its exit code
#
# Prints nothing
write_status() {
    printf '{"state": "%s", "reason": "%s", "started": %s, "finished": %s, "code": %s}\n' "$2" "$3" "$4" "$5" "$6" \
        > "${STATUS_PATH}/$1.json.tmp" && mv "${STATUS_PATH}/$1.json.tmp" "${STATUS_PATH}/$1.json"
}

# Whether a task is running now: its lock (/var/run/tasks-<id>.lock), with its process alive.
#
# $1 id The task's ID
#
# Returns 0 if it is
task_running() {
    local pid="$(cat "/var/run/tasks-$1.lock/pid" 2>/dev/null)"

    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

# Runs a task: its script as root (directly if it starts with #!, else with sh), in its own process group so it can be
# stopped with everything it started, with its time limit. Its output is its last run's log; how it went goes in its
# status, the history and (if the task asks) the ntfy app.
#
# $1 id     The task's ID
# $2 reason Why it runs: manual, schedule, boot or shutdown
#
# Prints nothing; returns 0 if it succeeded
run_task() {
    local id="$1"
    local reason="${2:-manual}"
    local script="${DATA_PATH}/scripts/${id}.sh"
    local lock="/var/run/tasks-${id}.lock"
    local output="${STATUS_PATH}/${id}.log"
    local name
    local timeout
    local started
    local pid
    local waited=0
    local state
    local code

    case "${id}" in
        *[!0-9a-f]* | '') return 2 ;;
    esac

    name="$(lib field "${DATA_PATH}" "${id}" name)" || return 2
    timeout="$(lib field "${DATA_PATH}" "${id}" timeout)"
    timeout="${timeout:-30}"

    if [ ! -f "${script}" ]; then
        log "task ${id} has no script"

        return 2
    fi

    # One run of a task at a time (a lock left by a run that died is taken over)
    if ! mkdir "${lock}" 2>/dev/null; then
        if task_running "${id}"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') ${name} (${reason}): skipped - it's still running" >> "${HISTORY}"

            return 1
        fi

        rm -rf "${lock}"
        mkdir "${lock}" || return 1
    fi

    echo $$ > "${lock}/pid"
    started="$(date +%s)"
    write_status "${id}" running "${reason}" "${started}" 0 0
    : > "${output}"
    chmod 600 "${output}"

    # Its own session (setsid, where there is one), so that stopping it stops what it started too
    (
        cd / || exit 1
        export TASK_ID="${id}" TASK_NAME="${name}" TASK_REASON="${reason}" HOME=/root
        [ -d /home/root ] && HOME=/home/root
        session=''
        command -v setsid > /dev/null 2>&1 && session=setsid

        if head -n 1 "${script}" | grep -q '^#!'; then
            exec ${session} "${script}"
        fi

        exec ${session} sh "${script}"
    ) < /dev/null >> "${output}" 2>&1 &
    pid=$!
    echo "${pid}" > "${lock}/child"

    while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt $((timeout * MINUTE)) ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "${pid}" 2>/dev/null; then
        stop_group "${pid}"
        wait "${pid}" 2>/dev/null
        state=timeout
        code=124
        echo "[Tasks] Stopped: it ran for longer than its ${timeout} minute(s)" >> "${output}"
    else
        wait "${pid}"
        code=$?
        state=ok
        [ "${code}" = 0 ] || state=failed
    fi

    # Its output's end only, if it's long
    if [ "$(wc -c < "${output}")" -gt "${OUTPUT_BYTES}" ]; then
        tail -c "${OUTPUT_BYTES}" "${output}" > "${output}.tmp" && mv "${output}.tmp" "${output}"
    fi

    write_status "${id}" "${state}" "${reason}" "${started}" "$(date +%s)" "${code}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${name} (${reason}): ${state}, exit code ${code}, $(($(date +%s) - started)) s" \
        >> "${HISTORY}"
    rm -rf "${lock}"
    lib notify "${DATA_PATH}" "${id}" > /dev/null 2>&1

    [ "${state}" = ok ]
}

# Stops a task's process group: politely, then (after 10 seconds) by force.
#
# $1 pid The task's process (its group's leader, from setsid)
#
# Prints nothing; returns 0
stop_group() {
    local waited=0

    kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null

    while kill -0 "$1" 2>/dev/null && [ "${waited}" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    kill -KILL -- "-$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null

    return 0
}

# Stops a task that's running (from its page): its run then ends as failed.
#
# $1 id The task's ID
#
# Prints nothing; returns 0 once stopped (1 if it wasn't running)
kill_task() {
    local child="$(cat "/var/run/tasks-$1.lock/child" 2>/dev/null)"

    task_running "$1" && [ -n "${child}" ] || return 1
    log "stopping task $1"
    echo '[Tasks] Stopped from its page' >> "${STATUS_PATH}/$1.log"
    stop_group "${child}"
}

# Runs the switched-on tasks with a trigger, one after another, in the page's order.
#
# $1 trigger boot or shutdown
#
# Prints nothing
run_all() {
    local id

    for id in $(lib ids "${DATA_PATH}" "$1"); do
        run_task "${id}" "$1"
    done
}

# Whether the NAS is shutting down or restarting (rather than the app being switched off, updated or removed): WD's
# shutdown and reboot programs are running.
#
# Returns 0 if it is
shutting_down() {
    ps 2>/dev/null | grep -v grep | grep -q -E '(shutdown\.sh|do_reboot|/sbin/(reboot|poweroff|halt))( |$)'
}

# Starts the app: schedules its tasks, then runs its boot tasks once per boot (in the background, so a slow one can't
# hold up the NAS's other apps; not again when the app is switched on or updated).
#
# Prints nothing; returns 0
start() {
    setup
    touch "${ACTIVE}"
    schedule

    if [ ! -f "${BOOTED}" ]; then
        touch "${BOOTED}"
        log 'running the boot tasks'
        nohup sh "${APP_PATH}/tasks_ctl.sh" boot > /dev/null 2>&1 &
    fi

    return 0
}

# Stops the app: runs its shutdown tasks if the NAS is going down (once, though WD may stop it twice), then takes its
# tasks out of cron.
#
# Prints nothing; returns 0
stop() {
    if shutting_down && [ ! -f "${SHUT_DOWN}" ]; then
        touch "${SHUT_DOWN}"
        log 'the NAS is shutting down: running the shutdown tasks'
        run_all shutdown
    fi

    unschedule
    rm -f "${ACTIVE}"

    return 0
}

# Keeps its logs small: the history to its last 1000 lines.
#
# Prints nothing; returns 0
daily() {
    if [ "$(wc -l < "${HISTORY}" 2>/dev/null || echo 0)" -gt 1000 ]; then
        tail -n 1000 "${HISTORY}" > "${HISTORY}.tmp" && mv "${HISTORY}.tmp" "${HISTORY}"
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    schedule) schedule ;;
    unschedule) unschedule ;;
    run) run_task "$2" "$3" ;;
    kill) kill_task "$2" ;;
    boot) run_all boot ;;
    shutdown) run_all shutdown ;;
    daily) daily ;;
    *)
        echo "Usage: $0 setup|start|stop|schedule|unschedule|run <id> [reason]|kill <id>|boot|shutdown|daily" >&2

        exit 1
        ;;
esac
