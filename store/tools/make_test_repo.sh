#!/bin/bash
# Builds a test repository - store.json (optionally signed), the built packages, the recipes and the apps' icons - in a
# folder that any HTTPS web server can serve, e.g. a site of the Nginx app on the NAS itself:
#
#     store/tools/make_test_repo.sh <folder> <base URL> [--sign-key <key.pem>] [--package-url <template>] [--link]
#     store/tools/make_test_repo.sh /mnt/x/Public/repo https://repo.nas.example.com/ --sign-key test.pem
#
# Then add <base URL>store.json in the Store (Repositories). Packages are those in packages/<app>/<version>/ for each
# app's current version (build them first, e.g. MODEL_OVERRIDE=MyCloudPR4100 ./build.sh <app>). --link links to the
# files instead of copying them (for a web server on this machine). --package-url defaults to
# <base URL>packages/{id}/{version}/{file}.
set -euo pipefail

if [ $# -lt 2 ]; then
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
fi
OUT="$1"
BASE="${2%/}/"
shift 2
SIGN=()
PACKAGE_URL="${BASE}packages/{id}/{version}/{file}"
LINK=0
while [ $# -gt 0 ]; do
	case "$1" in
		--sign-key) SIGN=(--sign-key "$2"); shift 2 ;;
		--package-url) PACKAGE_URL="$2"; shift 2 ;;
		--link) LINK=1; shift ;;
		*) echo "Unknown option: $1"; exit 1 ;;
	esac
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
place() {
	mkdir -p "$(dirname "$2")"
	if [ "${LINK}" = 1 ]; then ln -sfn "$1" "$2"; else cp -a "$1" "$2"; fi
}

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
rm -rf "${OUT}/packages" "${OUT}/recipes" "${OUT}/apps"
for rc in "${REPO}"/apps/*/apkg.rc; do
	app="$(basename "$(dirname "${rc}")")"
	[ "${app}" = template ] && continue
	id="$(sed -n 's/^Package:[[:space:]]*//p' "${rc}" | tr -d '\r')"
	version="$(sed -n 's/^Version:[[:space:]]*//p' "${rc}" | tr -d '\r')"
	icon="$(sed -n 's/^Icon:[[:space:]]*//p' "${rc}" | tr -d '\r')"
	for bin in "${REPO}/packages/${id}/${version}/${id}_${version}_"*.bin; do
		[ -f "${bin}" ] && place "${bin}" "${OUT}/packages/${id}/${version}/$(basename "${bin}")"
	done
	[ -n "${icon}" ] && [ -f "${REPO}/apps/${app}/web/${icon}" ] && place "${REPO}/apps/${app}/web/${icon}" "${OUT}/apps/${app}/web/${icon}"
done
for recipe in "${REPO}"/recipes/*/recipe.json; do
	place "$(dirname "${recipe}")" "${OUT}/recipes/$(basename "$(dirname "${recipe}")")"
done

python3 "${REPO}/store/tools/build_store.py" --output "${OUT}/store.json" --base-url "${BASE}" --package-url "${PACKAGE_URL}" "${SIGN[@]}"
echo "Test repository ready in ${OUT} - add ${BASE}store.json in the Store"
