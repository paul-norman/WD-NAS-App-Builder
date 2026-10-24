#!/bin/bash
# Tests the PHP app on a stand-in for the NAS's own PHP (see README.md):
#
#     tests/php/run_tests.sh
#
# Needs Docker (a privileged container: the app bind-mounts its patched copies of WD's pages) and the PHP app built for
# the PR4100 (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh php). Logs go in $PHP_TEST_WORK (default: $TMPDIR/php-tests).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${PHP_TEST_WORK:-${TMPDIR:-/tmp}/php-tests}"
mkdir -p "${WORK}"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/php/apkg.rc" | tr -d '\r')"
PACKAGE="${PROJ}/packages/php/${VERSION}/php_${VERSION}_amd64.tar.gz"
[ -f "${PACKAGE}" ] || { echo "Build the PHP app ${VERSION} first: MODEL_OVERRIDE=MyCloudPR4100 ./build.sh php"; exit 1; }
docker build -q -t nas-test-php74-fpm -f "${HERE}/image.Dockerfile" "${HERE}" > /dev/null || exit 1

log="${WORK}/app.log"
echo "== php"
docker run --rm --init --privileged -v "${HERE}/bin:/t/bin:ro" -v "${PACKAGE}:/pkg/php.tar.gz:ro" nas-test-php74-fpm \
	sh /t/bin/test_app.sh > "${log}" 2>&1
grep -E "^(PASS|FAIL)" "${log}" | cut -c1-170
passes=$(grep -c "^PASS" "${log}"); fails=$(grep -c "^FAIL" "${log}")
echo "   ${passes} passed, ${fails} failed (log: ${log})"
[ "${fails}" = 0 ] && [ "${passes}" != 0 ]
