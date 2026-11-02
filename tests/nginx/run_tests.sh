#!/bin/bash
# Tests the Nginx app in a stand-in for the NAS (see README.md):
#
#     tests/nginx/run_tests.sh [--php 7.4|8.5|both]
#
# Default: PHP 7.4 (WD's; the page runs on whichever PHP the NAS has). Needs Docker, and the Nginx and PHP apps built
# for the PR4100 (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh nginx php). Logs go in $NGINX_TEST_WORK (default:
# $TMPDIR/nginx-tests).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${NGINX_TEST_WORK:-${TMPDIR:-/tmp}/nginx-tests}"
PHP='7.4'
[ "${1:-}" = '--php' ] && PHP="${2:-7.4}"

case "${PHP}" in
    both) VERSIONS='74 85' ;;
    7.4) VERSIONS='74' ;;
    8.5) VERSIONS='85' ;;
    *) echo '--php is 7.4, 8.5 or both'; exit 1 ;;
esac

package() {
    local version
    version="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/$1/apkg.rc" | tr -d '\r')"
    echo "${PROJ}/packages/$1/${version}/$1_${version}_amd64.tar.gz"
}
NGINX="$(package nginx)"; PHPPKG="$(package php)"

for f in "${NGINX}" "${PHPPKG}"; do
    [ -f "${f}" ] || { echo "Build it first: ${f} (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh nginx php)"; exit 1; }
done

mkdir -p "${WORK}/bb"

for version in ${VERSIONS}; do
    if ! docker image inspect "nas-test-php${version}" > /dev/null 2>&1; then
        docker build -q -t "nas-test-php${version}" -f "${PROJ}/tests/images/php${version}.Dockerfile" "${PROJ}/tests/images" > /dev/null || exit 1
    fi
done

[ -x "${WORK}/bb/busybox" ] || docker run --rm -v "${WORK}/bb:/out" busybox:1.36-musl cp /bin/busybox /out/busybox

failed=0

for version in ${VERSIONS}; do
    log="${WORK}/app-php${version}.log"
    echo "== nginx (PHP ${version})"
    docker run --rm --init -v "${HERE}/bin:/t/bin:ro" -v "${WORK}/bb:/t/bb:ro" -v "${NGINX}:/pkg/nginx.tar.gz:ro" \
        -v "${PHPPKG}:/pkg/php.tar.gz:ro" "nas-test-php${version}" sh /t/bin/test_app.sh > "${log}" 2>&1
    grep -E '^(PASS|FAIL)' "${log}" | cut -c1-170
    passes=$(grep -c "^PASS" "${log}"); fails=$(grep -c "^FAIL" "${log}")
    echo "   ${passes} passed, ${fails} failed (log: ${log})"
    [ "${fails}" = 0 ] && [ "${passes}" != 0 ] || failed=1
done

exit ${failed}
