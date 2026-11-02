#!/bin/sh
# After a new install (the Store's post_install hook, also run by setup.sh): face recognition starts off unless
# FACIAL_RECOGNITION=on. It's saved in Immich's own settings - which hold only what differs from its defaults, so it
# stays changeable in Immich's settings page - then the server is restarted to read it. Only while Immich has no admin
# user yet: after that, it's Immich's own setting. Run in the recipe's folder, with .env's variables in the environment.

[ "${FACIAL_RECOGNITION}" = on ] && exit 0

echo 'Waiting for Immich to be ready (the first start sets up its database)'

waited=0

until [ "$(docker inspect -f '{{.State.Health.Status}}' immich_server 2>/dev/null)" = healthy ]; do
    if [ ${waited} -ge 600 ]; then
        echo "Immich wasn't ready within 10 minutes: face recognition is left as Immich's default (on)"

        exit 1
    fi
    sleep 5
    waited=$((waited + 5))
done

psql() {
    docker exec immich_postgres psql -U "${DB_USERNAME:-postgres}" -d "${DB_DATABASE_NAME:-immich}" -qAt -c "$1"
}

if [ "$(psql 'SELECT count(*) FROM "user"' 2>/dev/null)" != 0 ]; then
    exit 0
fi

if [ "$(psql "INSERT INTO system_metadata (key, value) VALUES ('system-config', '{\"machineLearning\": {\"facialRecognition\": {\"enabled\": false}}}') ON CONFLICT (key) DO NOTHING RETURNING key")" = system-config ]; then
    docker compose restart immich-server
    echo 'Face recognition is off (turn it on in Immich: Administration -> Settings -> Machine Learning Settings)'
fi
