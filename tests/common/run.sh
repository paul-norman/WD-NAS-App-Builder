#!/bin/bash
# Runs an app's suite (tests/<app>/test_app.sh, using tests/common/nas.sh) in a stand-in for the NAS, from the app's
# built package:
#
#     tests/common/run.sh <app> [--php 7.4|8.5|both]
#
# Extra options for its container, if it needs them (e.g. --privileged, to change the kernel settings the app changes on
# the NAS): tests/<app>/docker-options, one line ({project}: the repository's folder). The other apps a suite installs
# (apps that work together): their names in tests/<app>/with (built too; mounted at /pkg/<name>.tar.gz). A stand-in of
# its own (e.g. WD's MariaDB, for the MariaDB app): tests/<app>/image.Dockerfile, used in place of the PHP images.
#
# Default: PHP 7.4 (WD's - the page runs on whichever PHP the NAS has; the app itself always sees the NAS's glibc).
# Needs Docker and the app built for the PR4100 (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh <app>). Logs go in
# $APP_TEST_WORK (default: $TMPDIR/app-tests).
set -uo pipefail

COMMON="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${COMMON}/../.." && pwd)"
APP="${1:-}"
[ -n "${APP}" ] && [ -f "${PROJ}/tests/${APP}/test_app.sh" ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
PHP='7.4'
[ "${2:-}" = '--php' ] && PHP="${3:-7.4}"

case "${PHP}" in
    both) VERSIONS='74 85' ;;
    7.4) VERSIONS='74' ;;
    8.5) VERSIONS='85' ;;
    *) echo '--php is 7.4, 8.5 or both'; exit 1 ;;
esac
WORK="${APP_TEST_WORK:-${TMPDIR:-/tmp}/app-tests}"
mkdir -p "${WORK}/bb"
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/${APP}/apkg.rc" | tr -d '\r')"
PACKAGE="${PROJ}/packages/${APP}/${VERSION}/${APP}_${VERSION}_amd64.tar.gz"
[ -f "${PACKAGE}" ] || { echo "Build ${APP} ${VERSION} first: MODEL_OVERRIDE=MyCloudPR4100 ./build.sh ${APP}"; exit 1; }

if [ -f "${PROJ}/tests/${APP}/image.Dockerfile" ]; then
    VERSIONS="${APP}"
    docker build -q -t "nas-test-${APP}" -f "${PROJ}/tests/${APP}/image.Dockerfile" "${PROJ}/tests/${APP}" > /dev/null || exit 1
fi

for version in ${VERSIONS}; do
    [ "${version}" = "${APP}" ] && continue

    if ! docker image inspect "nas-test-php${version}" > /dev/null 2>&1; then
        docker build -q -t "nas-test-php${version}" -f "${PROJ}/tests/images/php${version}.Dockerfile" "${PROJ}/tests/images" > /dev/null || exit 1
    fi
done

[ -x "${WORK}/bb/busybox" ] || docker run --rm -v "${WORK}/bb:/out" busybox:1.36-musl cp /bin/busybox /out/busybox

# The package of each app (built for the PR4100)
package() {
    local version
    version="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/$1/apkg.rc" | tr -d '\r')"
    echo "${PROJ}/packages/$1/${version}/$1_${version}_amd64.tar.gz"
}
WITH=''

for other in $(cat "${PROJ}/tests/${APP}/with" 2>/dev/null); do
    [ -f "$(package "${other}")" ] || { echo "Build ${other} first: MODEL_OVERRIDE=MyCloudPR4100 ./build.sh ${other}"; exit 1; }
    WITH="${WITH} -v $(package "${other}"):/pkg/${other}.tar.gz:ro"
done

OPTIONS=''
[ -f "${PROJ}/tests/${APP}/docker-options" ] && OPTIONS="$(head -n 1 "${PROJ}/tests/${APP}/docker-options")"
OPTIONS="${OPTIONS//\{project\}/${PROJ}}"

failed=0

for version in ${VERSIONS}; do
    image="nas-test-php${version}"; log="${WORK}/${APP}-php${version}.log"; title="PHP ${version}"
    [ "${version}" = "${APP}" ] && image="nas-test-${APP}" && log="${WORK}/${APP}.log" && title='its own stand-in'
    echo "== ${APP} ${VERSION} (${title})"
    docker run --rm --init ${OPTIONS} ${WITH} -v "${COMMON}:/t/common:ro" -v "${PROJ}/tests/${APP}:/t/app:ro" -v "${WORK}/bb:/t/bb:ro" \
        -v "${PACKAGE}:/pkg/package.tar.gz:ro" "${image}" sh /t/app/test_app.sh > "${log}" 2>&1
    grep -E '^(PASS|FAIL)' "${log}" | cut -c1-170
    passes=$(grep -c "^PASS" "${log}"); fails=$(grep -c "^FAIL" "${log}")
    echo "   ${passes} passed, ${fails} failed (log: ${log})"
    [ "${fails}" = 0 ] && [ "${passes}" != 0 ] || failed=1
done

exit ${failed}
