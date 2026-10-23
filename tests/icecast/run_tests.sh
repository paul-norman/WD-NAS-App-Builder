#!/bin/bash
# Tests the Icecast app in a stand-in for the NAS (see README.md):
#
#     tests/icecast/run_tests.sh [app|page|package|all] [--php 7.4|8.5|both]
#
# Default: all, on PHP 7.4 (--php only changes the page group: the others always run on PHP 7.4's image, which has the
# NAS's glibc). Needs Docker and the app built for the PR4100 (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh icecast, which
# prepares static/icecast first). Work files go in $ICE_TEST_WORK (default: $TMPDIR/icecast-tests).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${ICE_TEST_WORK:-${TMPDIR:-/tmp}/icecast-tests}"
WHAT="${1:-all}"
PHP="7.4"
[ "${2:-}" = "--php" ] && PHP="${3:-7.4}"
case "${WHAT}" in
	all) TESTS="app page package" ;;
	app|page|package) TESTS="${WHAT}" ;;
	*) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
case "${PHP}" in
	both) VERSIONS="74 85" ;;
	7.4) VERSIONS="74" ;;
	8.5) VERSIONS="85" ;;
	*) echo "--php is 7.4, 8.5 or both"; exit 1 ;;
esac

# The app as built: its prepared binaries and its package
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/icecast/apkg.rc" | tr -d '\r')"
STATIC="${PROJ}/packages/static/icecast/${VERSION}/amd64"
PACKAGE="${PROJ}/packages/icecast/${VERSION}/icecast_${VERSION}_amd64.tar.gz"
if [ ! -x "${STATIC}/icecast" ] || [ ! -f "${PACKAGE}" ]; then
	echo "Build Icecast ${VERSION} first: MODEL_OVERRIDE=MyCloudPR4100 ./build.sh icecast"
	exit 1
fi

# The test images, shared by the test suites (built once)
for version in 74 ${VERSIONS}; do
	if ! docker image inspect "nas-test-php${version}" > /dev/null 2>&1; then
		echo "Building the PHP ${version} test image"
		docker build -q -t "nas-test-php${version}" -f "${PROJ}/tests/images/php${version}.Dockerfile" "${PROJ}/tests/images" > /dev/null
	fi
done

# The app's files (as the build puts them together), BusyBox with its user tools (static)
mkdir -p "${WORK}"
docker run --rm -v "${WORK}:${WORK}" busybox:1.36 rm -rf "${WORK}/app"
mkdir -p "${WORK}/app" "${WORK}/bb"
cp -r "${PROJ}/apps/icecast/." "${WORK}/app/"
cp "${PROJ}/apps/helpers.sh" "${PROJ}/apps/apkg_helpers.sh" "${WORK}/app/"
cp "${PROJ}/apps/manage_helpers.php" "${WORK}/app/manage/"
[ -x "${WORK}/bb/busybox" ] || docker run --rm -v "${WORK}/bb:/out" busybox:1.36-musl cp /bin/busybox /out/busybox

failed=0
for test in ${TESTS}; do
	versions="74"
	[ "${test}" = page ] && versions="${VERSIONS}"
	for version in ${versions}; do
		log="${WORK}/${test}-php${version}.log"
		echo "== ${test}$([ "${test}" = page ] && echo " (PHP ${version})")"
		# (a fresh stand-in NAS each time: nothing kept between runs)
		mounts=(-v "${HERE}/bin:/t/bin:ro" -v "${WORK}/bb:/t/bb:ro")
		if [ "${test}" = package ]; then
			mounts+=(-v "${PACKAGE}:/pkg/package.tar.gz:ro")
		else
			mounts+=(-v "${WORK}/app:/app:ro" -v "${STATIC}:/mnt/HD/HD_a2/Nas_Prog/icecast/binaries:ro")
		fi
		docker run --rm "${mounts[@]}" "nas-test-php${version}" sh "/t/bin/test_${test}.sh" > "${log}" 2>&1 || true
		grep -E "^(PASS|FAIL)" "${log}" | cut -c1-160 || true
		passes=$(grep -c "^PASS" "${log}" || true)
		fails=$(grep -c "^FAIL" "${log}" || true)
		echo "   ${passes} passed, ${fails} failed (log: ${log})"
		[ "${fails}" = 0 ] && [ "${passes}" != 0 ] || failed=1
	done
done
exit ${failed}
