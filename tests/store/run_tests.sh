#!/bin/bash
# Tests the Store app in a stand-in for the NAS (see README.md):
#
#     tests/store/run_tests.sh [repos_apps|recipes|auto|immich|pihole|arr|signatures|ui|all] [--php 7.4|8.5|both]
#
# Default: all (except ui) on PHP 7.4. Needs Docker on Linux (host networking; ports 8080, 8443, 18081 and 2283 free),
# Python 3, and the apps' packages built for the PR4100 (the Store's is built here). Work files go in $STORE_TEST_WORK
# (default: $TMPDIR/store-tests).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${STORE_TEST_WORK:-${TMPDIR:-/tmp}/store-tests}"
WHAT="${1:-all}"
PHP='7.4'
[ "${2:-}" = '--php' ] && PHP="${3:-7.4}"

case "${WHAT}" in
    all) TESTS='repos_apps recipes auto immich pihole arr signatures' ;;
    repos_apps|recipes|auto|immich|pihole|arr|signatures|ui) TESTS="${WHAT}" ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

case "${PHP}" in
    both) VERSIONS='74 85' ;;
    7.4) VERSIONS='74' ;;
    8.5) VERSIONS='85' ;;
    *) echo '--php is 7.4, 8.5 or both'; exit 1 ;;
esac

# The test images, shared by the test suites (built once)
for version in ${VERSIONS}; do
    if ! docker image inspect "nas-test-php${version}" > /dev/null 2>&1; then
        echo "Building the PHP ${version} test image"
        docker build -q -t "nas-test-php${version}" -f "${PROJ}/tests/images/php${version}.Dockerfile" "${PROJ}/tests/images" > /dev/null
    fi
done

mkdir -p "${WORK}/certs" "${WORK}/fixtures"

# A test certificate authority (trusted only inside the test containers) for repo.test and evil.test, and two signing
# keys
if [ ! -f "${WORK}/certs/server.pem" ]; then
    (
        cd "${WORK}/certs"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -days 365 -subj '/CN=Store Test CA' 2> /dev/null
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj '/CN=repo.test' 2> /dev/null
        printf "subjectAltName=DNS:repo.test,DNS:evil.test\n" > ext.cnf
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 365 -extfile ext.cnf 2> /dev/null
        openssl genpkey -algorithm ed25519 -out keyA.pem
        openssl genpkey -algorithm ed25519 -out keyB.pem
    )
fi

# Fixtures: the test recipe, and a copy of the Immich recipe for this machine (no Intel GPU device, a lower disk
# requirement - test machines' /tmp is often small)
rm -rf "${WORK}/fixtures"/*
cp -r "${HERE}/fixtures/hello-1" "${HERE}/fixtures/hello-2" "${WORK}/fixtures/"
cp -r "${PROJ}/recipes/immich" "${WORK}/fixtures/immich-small"
rm -f "${WORK}/fixtures/immich-small/"{setup.sh,example.env,README.md}
python3 - "${WORK}/fixtures/immich-small" <<'EOF'
import json, pathlib, re, sys
folder = pathlib.Path(sys.argv[1])
recipe = json.loads((folder / "recipe.json").read_text())
recipe["requires"]["disk_mb"] = 2048
(folder / "recipe.json").write_text(json.dumps(recipe, indent="\t"))
compose = (folder / "compose.yaml").read_text()
(folder / "compose.yaml").write_text(re.sub(r"    devices:\n(?:      #.*\n)*      - /dev/dri:/dev/dri\n", "", compose))
EOF
printf 'not really a photo\n' > "${WORK}/fixtures/photo.jpg"
# ... and of the Arr stack recipe (a lower disk requirement)
cp -r "${PROJ}/recipes/arr" "${WORK}/fixtures/arr-small"
rm -f "${WORK}/fixtures/arr-small/"{setup.sh,example.env,README.md}
python3 - "${WORK}/fixtures/arr-small" <<'EOF'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
recipe = json.loads((folder / "recipe.json").read_text())
recipe["requires"]["disk_mb"] = 2048
(folder / "recipe.json").write_text(json.dumps(recipe, indent="\t"))
EOF
# ... and a copy of the Pi-hole recipe on ports this machine has free (1053 for DNS, 18053 for its web interface)
cp -r "${PROJ}/recipes/pihole" "${WORK}/fixtures/pihole-ports"
rm -f "${WORK}/fixtures/pihole-ports/"{setup.sh,example.env,README.md}
python3 - "${WORK}/fixtures/pihole-ports" <<'EOF'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
recipe = json.loads((folder / "recipe.json").read_text())
recipe["id"] = recipe["project"] = "pihole-ports"
recipe["data_folder"] = "_pihole-ports"
recipe["web"]["port"] = 18053
(folder / "recipe.json").write_text(json.dumps(recipe, indent="\t"))
compose = (folder / "compose.yaml").read_text()
compose = compose.replace("'53:53/", "'1053:53/").replace("'8053:80/tcp'", "'18053:80/tcp'").replace("name: pihole", "name: pihole-ports")
(folder / "compose.yaml").write_text(compose)
hook = (folder / "hooks/pre_install.sh").read_text()
(folder / "hooks/pre_install.sh").write_text(hook.replace("'tcp 53 0035' 'udp 53 0035' 'tcp 8053 1F75'", "'tcp 1053 041D' 'udp 1053 041D' 'tcp 18053 4685'"))
EOF

echo 'Building the Store app'
(cd "${PROJ}" && MODEL_OVERRIDE=MyCloudPR4100 ./build.sh store > "${WORK}/build.log" 2>&1) || { echo "The Store didn't build - see ${WORK}/build.log"; exit 1; }

failed=0
# Registry logins of the machine running the suite (e.g. CI's to ghcr.io), for the Store's image downloads: anonymous
# ones are refused in bursts ("toomanyrequests") on shared addresses such as CI's. Only logins kept in the file itself:
# a credential helper (e.g. Docker Desktop's) isn't there in the stand-in NAS
DOCKER_LOGIN=''
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"

if [ -f "${DOCKER_CONFIG_FILE}" ] && ! grep -q '"credsStore"\|"credHelpers"' "${DOCKER_CONFIG_FILE}"; then
    DOCKER_LOGIN="-v ${DOCKER_CONFIG_FILE}:/root/.docker/config.json:ro"
fi

for version in ${VERSIONS}; do
    for test in ${TESTS}; do
        # A fresh NAS stand-in and test repository for each test (the containers leave root-owned files)
        docker run --rm -v "${WORK}:${WORK}" busybox:1.36 rm -rf "${WORK}/vol" "${WORK}/www"
        "${PROJ}/store/tools/make_test_repo.sh" "${WORK}/www/repo" https://repo.test:8443/ \
            --package-url 'https://repo.test:8443/releases/{id}/{version}/{file}' --link 2>&1 | grep -v '^warning: no packages' > /dev/null
        # The apps the tests install: test apps of their own, without and with keeps_data (no app needs building)
        python3 "${HERE}/bin/repotool.py" add-app "${WORK}/www/repo" plain false
        python3 "${HERE}/bin/repotool.py" add-app "${WORK}/www/repo" keeper true
        log="${WORK}/${test}-php${version}.log"
        echo "== ${test} (PHP ${version})"
        # The page stays up for a browser: its output comes straight here
        [ "${test}" = ui ] && log=/dev/stdout
        docker run --rm --network host -e STORE_TEST_VOLUME="${WORK}/vol/HD_a2" -e STORE_TEST_PROJECT="${PROJ}" \
            -v "${WORK}/vol:${WORK}/vol" -v "${HERE}/bin:/tbin:ro" -v "${WORK}/certs:/tcerts:ro" -v "${WORK}/fixtures:/tfix:ro" \
            -v "${WORK}/www:/www" -v "${PROJ}:${PROJ}:ro" -v /var/run/docker.sock:/var/run/docker.sock \
            ${DOCKER_LOGIN} \
            "nas-test-php${version}" sh -c 'sh /tbin/prepare.sh && sh "$0"' "/tbin/test_${test}.sh" > "${log}" 2>&1 || true
        [ "${test}" = ui ] && continue
        grep -E '^(PASS|FAIL)' "${log}" | cut -c1-160 || true
        passes=$(grep -c "^PASS" "${log}" || true)
        fails=$(grep -c "^FAIL" "${log}" || true)
        echo "   ${passes} passed, ${fails} failed (log: ${log})"
        [ "${fails}" = 0 ] && [ "${passes}" != 0 ] || failed=1
    done
done

exit ${failed}
