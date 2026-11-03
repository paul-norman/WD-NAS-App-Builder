#!/bin/bash
# One CI job (see README.md): an app's package and its tests, or a recipe's tests:
#
#     ci/job.sh app <app> build|fetch yes|no
#     ci/job.sh recipe <id>
#
# For an app: gets its package (ci/package.sh), copies what a release would publish into dist/<app>/ (before any test
# rebuilds it) with, when SOURCES=yes, its sources (ci/sources.py release), gets the packages its suite needs (built
# when they're in BUILD_SET, the apps this run builds, else fetched), then runs the shared package test and, with yes,
# its own suite (ci/tests.conf). For a recipe: gets the packages its suite needs, then runs it. Every test runs even
# after one fails; exits non-zero if any did.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Git here doesn't keep the scripts' execute bits (core.fileMode false on Windows drives), so set them as build.sh does
find . -path ./packages -prune -o -type f -name '*.sh' -exec chmod +x {} +

KIND="$1"
NAME="$2"
FAILED=''

# Gets the packages a suite needs.
#
# $1 suite The suite's name (an app, or recipe:<id>)
#
# Returns 0 once all are got, 1 if one couldn't be
get_needs() {
    local need

    for need in $(python3 ci/plan.py --tests "$1" | head -n 1); do
        if [[ " ${BUILD_SET:-} " == *" ${need} "* ]]; then
            ci/package.sh "${need}" build || return 1
        else
            ci/package.sh "${need}" fetch || return 1
        fi
    done

    return 0
}

# Runs a suite's commands, each in a group of the log.
#
# $1 suite The suite's name
#
# Prints their output; adds each failed command to FAILED
run_suite() {
    local command

    while IFS= read -r command; do
        echo "::group::${command}"
        bash -c "${command}"
        local status=$?
        echo '::endgroup::'

        if [ "${status}" != 0 ]; then
            echo "::error::Failed: ${command}"
            FAILED="${FAILED}"$'\n'"${command}"
        fi
    done < <(python3 ci/plan.py --tests "$1" | tail -n +2)
}

if [ "${KIND}" = 'recipe' ]; then
    get_needs "recipe:${NAME}" || exit 1
    run_suite "recipe:${NAME}"
else
    MODE="${3:-build}"
    SUITE="${4:-yes}"
    ci/package.sh "${NAME}" "${MODE}" || exit 1

    if [ "${MODE}" = 'build' ]; then
        VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "apps/${NAME}/apkg.rc" | tr -d '\r')"
        rm -rf "dist/${NAME}"
        mkdir -p "dist/${NAME}"
        cp "packages/${NAME}/${VERSION}/${NAME}_${VERSION}_"*.bin "dist/${NAME}/"
        cp "packages/${NAME}/${VERSION}/${NAME}_${VERSION}_amd64.tar.gz" "dist/${NAME}/"
        printf '%s' "${VERSION}" > "dist/${NAME}/version"

        # The sources a release needs (SOURCES=yes: an app to release); without all of them it isn't released
        if [ "${SOURCES:-no}" = 'yes' ]; then
            echo "::group::Sources of ${NAME} ${VERSION}"
            python3 ci/sources.py release "${NAME}" "dist/${NAME}"
            STATUS=$?
            echo '::endgroup::'

            if [ "${STATUS}" != 0 ]; then
                echo "::error::The sources of ${NAME} ${VERSION} couldn't all be fetched"

                exit 1
            fi
        fi
    fi

    echo "::group::Shared package test: ${NAME}"
    tests/apps/run_tests.sh "${NAME}" || FAILED="${FAILED}"$'\n'"tests/apps/run_tests.sh ${NAME}"
    echo '::endgroup::'

    if [ "${SUITE}" = 'yes' ]; then
        if get_needs "${NAME}"; then
            run_suite "${NAME}"
        else
            FAILED="${FAILED}"$'\n'"the packages ${NAME}'s suite needs"
        fi
    fi
fi

if [ -n "${FAILED}" ]; then
    echo "Failed:${FAILED}"

    exit 1
fi

echo 'All passed'
