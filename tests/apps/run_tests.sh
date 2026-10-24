#!/bin/bash
# The shared package test (see README.md): every app's built package through its life as WD's installer runs it, each in
# a fresh stand-in for the NAS:
#
#     tests/apps/run_tests.sh [app ...]
#
# Default: every app in apps.conf. Needs Docker and the apps built for the PR4100 (MODEL_OVERRIDE=MyCloudPR4100
# ./build.sh <app>). Work files (logs) go in $APPS_TEST_WORK (default: $TMPDIR/apps-tests).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/../.." && pwd)"
WORK="${APPS_TEST_WORK:-${TMPDIR:-/tmp}/apps-tests}"
mkdir -p "${WORK}/bb"

if ! docker image inspect nas-test-php74 > /dev/null 2>&1; then
	echo "Building the PHP 7.4 test image"
	docker build -q -t nas-test-php74 -f "${PROJ}/tests/images/php74.Dockerfile" "${PROJ}/tests/images" > /dev/null || exit 1
fi
[ -x "${WORK}/bb/busybox" ] || docker run --rm -v "${WORK}/bb:/out" busybox:1.36-musl cp /bin/busybox /out/busybox

APPS=("$@")
[ ${#APPS[@]} = 0 ] && APPS=($(grep -vE '^(#|$)' "${HERE}/apps.conf" | awk '{ print $1 }'))

failed=0
summary=""
for app in "${APPS[@]}"; do
	line="$(grep -E "^${app}[[:space:]]" "${HERE}/apps.conf")"
	if [ -z "${line}" ]; then
		echo "${app}: not in apps.conf"
		failed=1
		continue
	fi
	check="$(echo "${line}" | awk '{ print $2 }')"
	[[ "${check}" == cmd:* ]] && check="$(echo "${line}" | sed -E 's/^[^[:space:]]+[[:space:]]+//')"
	version="$(sed -n 's/^Version:[[:space:]]*//p' "${PROJ}/apps/${app}/apkg.rc" | tr -d '\r')"
	package="${PROJ}/packages/${app}/${version}/${app}_${version}_amd64.tar.gz"
	if [ ! -f "${package}" ]; then
		echo "== ${app} ${version}: not built (MODEL_OVERRIDE=MyCloudPR4100 ./build.sh ${app})"
		failed=1
		continue
	fi
	data="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['apps'].get(sys.argv[2], {}).get('data_folder', ''))" "${PROJ}/store/metadata.json" "${app}")"
	echo "== ${app} ${version}"
	log="${WORK}/${app}.log"
	# (a TUN device for the VPNs)
	extra=()
	case "${app}" in wireguard|tailscale) extra=(--cap-add NET_ADMIN --device /dev/net/tun) ;; esac
	docker run --rm --init "${extra[@]}" -e DATA_FOLDER="${data}" -v "${HERE}/bin:/t/bin:ro" -v "${WORK}/bb:/t/bb:ro" \
		-v "${package}:/pkg/package.tar.gz:ro" nas-test-php74 sh /t/bin/lifecycle.sh "${app}" "${check}" > "${log}" 2>&1
	grep -E "^(PASS|FAIL)" "${log}" | sed 's/^/  /' | cut -c1-170
	passes=$(grep -c "^PASS" "${log}")
	fails=$(grep -c "^FAIL" "${log}")
	[ "${fails}" = 0 ] && [ "${passes}" != 0 ] || { failed=1; summary="${summary} ${app}"; }
done
[ -n "${summary}" ] && echo "Failed:${summary} (logs: ${WORK})" || echo "All passed (logs: ${WORK})"
exit ${failed}
