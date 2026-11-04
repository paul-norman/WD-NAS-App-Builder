#!/bin/bash
# Gets an app's packages into packages/<app>/<version>/ for CI (see README.md), by building them or by fetching them
# from the app's release:
#
#     ci/package.sh <app> build|fetch
#
# build: builds every model (./build.sh), its static build (with its survey, <arch>.sources) restored from the build
# cache (the build-cache release's assets, named after a hash of static/<app>, build_static.sh and the survey's scripts)
# when there, and added to it when not and CACHE_UPLOAD=yes. fetch: downloads the PR4100 package and the amd64 bundle
# the tests use from the release of its version, and builds it if there's none. Needs gh (GH_TOKEN) and zstd. Each app
# is only got once per job.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

APP="$1"
MODE="${2:-build}"
CACHE_RELEASE='build-cache'
MIRROR_RELEASE='source-mirror'
# GitHub's limit for a release asset
CACHE_MAX_BYTES=$((2 * 1024 * 1024 * 1024 - 1))
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "apps/${APP}/apkg.rc" | tr -d '\r')"
DIR="packages/${APP}/${VERSION}"
TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-package"

if [ -f "${DIR}/.ci-ready" ]; then
    echo "${APP} ${VERSION}: already got"

    exit 0
fi

mkdir -p "${TEMP}"

# The static build's version, from static/<app>/build.sh.
#
# Prints it
static_version() {
    sed -n 's/^VERSION=//p' "static/${APP}/build.sh" | head -n 1
}

# The cache key of the app's static build: what it's built from (static/<app> as committed, build_static.sh and the
# survey's scripts - ci/release.py computes it too).
#
# Prints it (16 hex digits)
static_key() {
    printf '%s %s %s %s' "$(git rev-parse "HEAD:static/${APP}")" "$(git hash-object build_static.sh)" \
        "$(git hash-object ci/survey.sh)" "$(git hash-object ci/survey_inside.sh)" | sha256sum | cut -c1-16
}

# Restores the app's static build (amd64) from the build cache, unless it's already there.
#
# Returns 0 if it was restored, 1 if not
restore_static() {
    local version
    local asset
    version="$(static_version)"
    asset="${APP}_${version}_amd64_$(static_key).tar.zst"

    if [ -n "$(ls -A "packages/static/${APP}/${version}/amd64" 2>/dev/null)" ]; then
        return 1
    fi

    rm -f "${TEMP}/${asset}"

    if ! gh release download "${CACHE_RELEASE}" -p "${asset}" -D "${TEMP}" > /dev/null 2>&1; then
        echo "Static ${APP} ${version}: not in the build cache (${asset})"

        return 1
    fi

    mkdir -p "packages/static/${APP}/${version}"
    tar -I zstd -xf "${TEMP}/${asset}" -C "packages/static/${APP}/${version}" || return 1
    printf '%s' "${version}" > "packages/static/${APP}/latest"
    rm -f "${TEMP}/${asset}"
    echo "Static ${APP} ${version}: restored from the build cache (${asset})"

    return 0
}

# Adds the app's static build (amd64) to the build cache.
#
# Prints what it did; returns 0 (a failed upload only costs a rebuild later)
save_static() {
    local version
    local asset
    version="$(static_version)"
    asset="${APP}_${version}_amd64_$(static_key).tar.zst"

    if [ ! -d "packages/static/${APP}/${version}/amd64" ]; then
        return 0
    fi

    local parts='amd64'
    [ -d "packages/static/${APP}/${version}/amd64.sources" ] && parts='amd64 amd64.sources'
    # shellcheck disable=SC2086
    tar -I 'zstd -T0 -12' -cf "${TEMP}/${asset}" -C "packages/static/${APP}/${version}" ${parts} || return 0

    if [ "$(stat -c %s "${TEMP}/${asset}")" -gt "${CACHE_MAX_BYTES}" ]; then
        echo "::warning::Static ${APP} ${version} is too big for the build cache" \
            "($(du -h "${TEMP}/${asset}" | cut -f1))"
        rm -f "${TEMP}/${asset}"

        return 0
    fi

    # Several jobs may create it at once: the losers' errors don't matter
    if ! gh release view "${CACHE_RELEASE}" > /dev/null 2>&1; then
        gh release create "${CACHE_RELEASE}" --prerelease --latest=false --title 'Build cache (not for installing)' \
            --notes 'Static builds reused by CI (see ci/README.md). Nothing here is meant to be installed.' \
            > /dev/null 2>&1
    fi

    if gh release upload "${CACHE_RELEASE}" "${TEMP}/${asset}" --clobber > /dev/null; then
        echo "Static ${APP} ${version}: added to the build cache (${asset})"
    else
        echo "::warning::Static ${APP} ${version} couldn't be added to the build cache"
    fi

    rm -f "${TEMP}/${asset}"

    return 0
}

# Adds the downloads this build made (static/fetch.sh keeps each in packages/mirror, named after its SHA256) to the
# mirror the builds fall back on, if it hasn't them yet.
#
# Prints what it added; returns 0 (a failed upload only means one fewer fallback)
save_mirror() {
    local listed
    local file

    [ -n "$(ls -A packages/mirror 2>/dev/null)" ] || return 0

    if ! gh release view "${MIRROR_RELEASE}" > /dev/null 2>&1; then
        gh release create "${MIRROR_RELEASE}" --prerelease --latest=false \
            --title 'Source mirror (what the builds download)' \
            --notes "Copies of the files the builds download, named after their SHA256: the builds fall back on them \
when a site is down (see ci/README.md). Nothing here is meant to be installed." \
            > /dev/null 2>&1
    fi

    listed=" $(gh release view "${MIRROR_RELEASE}" --json assets --jq '.assets[].name' 2>/dev/null | tr '\n' ' ') "

    for file in packages/mirror/*; do
        case "${file}" in
            *.part) continue ;;
        esac

        [[ "${listed}" == *" $(basename "${file}") "* ]] && continue

        if gh release upload "${MIRROR_RELEASE}" "${file}" > /dev/null; then
            echo "Mirror: added $(basename "${file}")"
        else
            echo "::warning::Mirror: $(basename "${file}") couldn't be added"
        fi
    done

    return 0
}

# Fetches the app's PR4100 package and amd64 bundle from the release of its version.
#
# Returns 0 if they were fetched, 1 if not
fetch() {
    local tag="${APP}-v${VERSION}"
    mkdir -p "${DIR}"

    if ! gh release download "${tag}" -p "${APP}_${VERSION}_MyCloudPR4100.bin" -p "${APP}_${VERSION}_amd64.tar.gz" \
        -D "${DIR}" --clobber; then
        echo "${APP} ${VERSION}: couldn't fetch its release (${tag}) - building it"

        return 1
    fi

    echo "${APP} ${VERSION}: fetched from its release (${tag})"

    return 0
}

if [ "${MODE}" = 'fetch' ] && fetch; then
    printf '%s' "${VERSION}" > "packages/${APP}/latest"

    # The tests of an app with a static build use it too (e.g. its binaries, run directly): from the build cache, else
    # the app is built after all
    if [ -d "static/${APP}" ]; then
        restore_static
    fi

    if [ ! -d "static/${APP}" ] || [ -n "$(ls -A "packages/static/${APP}/$(static_version)/amd64" 2>/dev/null)" ]; then
        touch "${DIR}/.ci-ready"

        exit 0
    fi

    echo "${APP} ${VERSION}: its static build isn't in the build cache - building it"
fi

RESTORED=1

if [ -d "static/${APP}" ]; then
    restore_static
    RESTORED=$?
fi

echo "::group::Building ${APP} ${VERSION}"
./build.sh "${APP}"
STATUS=$?
echo '::endgroup::'

if [ "${STATUS}" != 0 ]; then
    echo "::error::${APP} ${VERSION} didn't build"

    exit 1
fi

if [ -d "static/${APP}" ] && [ "${RESTORED}" != 0 ] && [ "${CACHE_UPLOAD:-no}" = 'yes' ]; then
    save_static
fi

# Like the build cache, the mirror holds builds' downloads (some of them others' programs), so it fills when releases do
if [ "${CACHE_UPLOAD:-no}" = 'yes' ]; then
    save_mirror
fi

touch "${DIR}/.ci-ready"
