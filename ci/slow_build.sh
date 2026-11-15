#!/bin/bash
# One job's part of a static build that takes longer than a CI job may run (ci/package.sh's SLOW_STATIC: Node.js's ARM
# build), for the slow-builds workflow:
#
#     ci/slow_build.sh <app> <minutes>
#
# Unless the build cache already has the app's static build, it builds the app (ci/package.sh, which adds the static
# build to the build cache when CACHE_UPLOAD=yes) with its compiler cache (ccache) from the build cache's
# ccache_<app>.tar.zst, stopping its compiling after <minutes>, and then keeps the compiler cache there again - a next
# job carries on from it (as does the next version's build: most of its source is unchanged). The app's static build
# reads its settings from packages/build-state/<app>/ (static/nodejs/build.sh). Writes done=cached, yes or no (time
# ran out) to GITHUB_OUTPUT; returns 1 if the build failed. Needs gh (GH_TOKEN) and zstd.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

APP="$1"
MINUTES="$2"
CACHE_RELEASE='build-cache'
CCACHE_ASSET="ccache_${APP}.tar.zst"
STATE="packages/build-state/${APP}"
TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-slow-build"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
VERSION="$(sed -n 's/^VERSION=//p' "static/${APP}/build.sh" | head -n 1)"
# The static build's cache key, as ci/package.sh names it
KEY="$(printf '%s %s %s %s' "$(git rev-parse "HEAD:static/${APP}")" "$(git hash-object build_static.sh)" \
    "$(git hash-object ci/survey.sh)" "$(git hash-object ci/survey_inside.sh)" | sha256sum | cut -c1-16)"
ASSET="${APP}_${VERSION}_amd64_${KEY}.tar.zst"

# The build cache's asset names.
#
# Prints them, one a line
cache_assets() {
    gh release view "${CACHE_RELEASE}" --json assets --jq '.assets[].name' 2>/dev/null
}

if cache_assets | grep -qxF "${ASSET}"; then
    echo "Static ${APP} ${VERSION} is in the build cache already (${ASSET})"
    echo 'done=cached' >> "${OUTPUT}"

    exit 0
fi

mkdir -p "${STATE}/ccache" "${TEMP}"
rm -f "${STATE}/timed-out"
echo $((MINUTES * 60)) > "${STATE}/time-limit"

if cache_assets | grep -qxF "${CCACHE_ASSET}" \
    && gh release download "${CACHE_RELEASE}" -p "${CCACHE_ASSET}" -D "${TEMP}" --clobber > /dev/null; then
    tar -I zstd -xf "${TEMP}/${CCACHE_ASSET}" -C "${STATE}/ccache"
    rm -f "${TEMP}/${CCACHE_ASSET}"
    echo "Compiler cache restored: $(du -sh "${STATE}/ccache" | cut -f1)"
else
    echo 'No compiler cache yet: starting from nothing'
fi

SLOW_BUILD=yes bash ci/package.sh "${APP}" build
STATUS=$?

# The compiler cache is kept whatever happened (a failure after hours of compiling needn't redo them), only by runs
# that may add to the build cache
if [ "${CACHE_UPLOAD:-no}" = yes ] && [ -n "$(ls -A "${STATE}/ccache" 2>/dev/null)" ]; then
    # (ccache's own files are compressed already)
    tar -I 'zstd -T0 -3' -cf "${TEMP}/${CCACHE_ASSET}" -C "${STATE}/ccache" .

    if gh release upload "${CACHE_RELEASE}" "${TEMP}/${CCACHE_ASSET}" --clobber > /dev/null; then
        echo "Compiler cache kept: $(du -h "${TEMP}/${CCACHE_ASSET}" | cut -f1)"
    else
        echo "::warning::The compiler cache couldn't be kept: the next job starts from nothing"
    fi

    rm -f "${TEMP}/${CCACHE_ASSET}"
fi

if [ "${STATUS}" = 0 ]; then
    echo 'done=yes' >> "${OUTPUT}"

    exit 0
fi

if [ -f "${STATE}/timed-out" ]; then
    echo "::notice::Static ${APP} ${VERSION}: time ran out after ${MINUTES} minutes - the next job carries on"
    echo 'done=no' >> "${OUTPUT}"

    exit 0
fi

echo "::error::Static ${APP} ${VERSION} didn't build"

exit 1
