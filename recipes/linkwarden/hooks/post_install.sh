#!/bin/sh
# After a new install (the Store's post_install hook, also run by setup.sh): makes Linkwarden's admin account - the
# wizard's ADMIN_USERNAME and ADMIN_PASSWORD - so that nobody else can claim it. Linkwarden only lets the admin add
# accounts once sign-ups are off, and its first account is the admin, so it's made with sign-ups on for a moment: its
# container is made again with them on (Linkwarden listens on the NAS itself only, and its Nginx site isn't added until
# after this step), the account is signed up through its API, then the container is made again with them off. Then its
# address (hooks/site.sh). Run in the recipe's folder, with .env's variables in the environment.

HOOKS="$(dirname "$(readlink -f "$0")")"
URL=http://127.0.0.1:3003

# Waits (up to 10 minutes - its first start sets up its database) for Linkwarden to answer.
#
# Returns 0 once it answers
wait_up() {
    local waited=0

    until [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${URL}/login" 2>/dev/null)" = 200 ]; do
        if [ ${waited} -ge 600 ]; then
            return 1
        fi

        sleep 5
        waited=$((waited + 5))
    done
}

echo 'Waiting for Linkwarden to be ready (its first start sets up its database)'

if ! wait_up; then
    echo "Linkwarden wasn't ready within 10 minutes: no admin account made (see: docker logs linkwarden)"

    exit 1
fi

# An existing account (e.g. installed again on kept data): nothing to make
if [ "$(docker exec linkwarden_postgres psql -U postgres -qAt -c 'SELECT count(*) FROM "User"' 2>/dev/null)" != 0 ]; then
    echo 'Linkwarden already has accounts: no admin account made'
    sh "${HOOKS}/site.sh"

    exit 0
fi

echo 'Making the admin account (sign-ups on for a moment, on the NAS itself only)'
DISABLE_REGISTRATION=false docker compose up -d linkwarden

if ! wait_up; then
    docker compose up -d linkwarden
    echo "Linkwarden wasn't ready again: no admin account made"

    exit 1
fi

# (the password given in the request's body, from the environment: never on a command line)
code="$(php -r 'echo json_encode(["name" => getenv("ADMIN_USERNAME"), "username" => getenv("ADMIN_USERNAME"),
    "password" => getenv("ADMIN_PASSWORD")]);' \
    | curl -s -m 60 -o /tmp/linkwarden-signup.json -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
        "${URL}/api/v1/users")"

# Sign-ups off again, whatever happened
docker compose up -d linkwarden

if [ "${code}" != 200 ] && [ "${code}" != 201 ]; then
    echo "Linkwarden refused the admin account (${code}): $(head -c 300 /tmp/linkwarden-signup.json 2>/dev/null)"
    rm -f /tmp/linkwarden-signup.json

    exit 1
fi

rm -f /tmp/linkwarden-signup.json
echo "Made the admin account: ${ADMIN_USERNAME}"
wait_up
sh "${HOOKS}/site.sh"
