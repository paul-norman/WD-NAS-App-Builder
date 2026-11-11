#!/bin/sh
# After an install, an update or a change of settings (the Store's post_install, post_update and post_change hooks,
# also run by setup.sh): writes the recipe's "Object detection" setting into Frigate's settings - see configure.py - and
# restarts Frigate if they changed; on a new install, also sets the admin user's password. Run in the recipe's folder,
# with .env's variables in the environment. configure.py runs inside Frigate's own image, which has what it needs.

HOOKS="$(cd "$(dirname "$0")" && pwd)"

# Runs configure.py in a throwaway container of Frigate's image (with Frigate's settings folder), and prints its
# output without Compose's own progress lines.
#
# $1 mode detectors or password
#
# Sets RESULT to configure.py's exit code
configure() {
    local output

    RESULT=0
    output="$(docker compose run --rm --no-deps -T --entrypoint python3 -v "${HOOKS}:/hooks:ro" \
        -e DETECTOR -e REMOTE_DETECTOR -e ADMIN_PASSWORD -e FRIGATE_VERSION \
        frigate /hooks/configure.py "$1" 2>&1)" || RESULT=$?
    printf '%s\n' "${output}" | grep -v -e '^ *Container ' -e '^time=' -e '^\[+\]'
}

PROBLEM=0
configure detectors

case "${RESULT}" in
    0) ;;
    10)
        echo 'Restarting Frigate to use it'
        docker compose restart frigate > /dev/null 2>&1
        ;;
    *) PROBLEM=1 ;;
esac

if [ "${STORE_ACTION:-install}" = install ] && [ -n "${ADMIN_PASSWORD}" ]; then
    echo "Setting Frigate's admin password (once it has started for the first time)"
    configure password
    [ "${RESULT}" = 0 ] || PROBLEM=1
fi

exit "${PROBLEM}"
