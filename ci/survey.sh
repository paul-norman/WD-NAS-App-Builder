#!/bin/bash
# Records the distribution packages a static build may have put into its output (see README.md, Sources): each stage of
# its Dockerfile is surveyed (ci/survey_inside.sh) with the output mounted, into
# packages/static/<app>/<version>/<arch>.sources/distro.tsv - for ci/sources.py, which fetches the sources of those
# that need them. Run by build_static.sh after a build:
#
#     bash ci/survey.sh <app> <arch> <version>
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

APP="$1"
ARCH="$2"
VERSION="$3"
DOCKERFILE="static/${APP}/${ARCH}.Dockerfile"
OUTPUT="packages/static/${APP}/${VERSION}/${ARCH}"
SOURCES="${OUTPUT}.sources"

case "${ARCH}" in
    amd64) PLATFORM='linux/amd64' ;;
    *) PLATFORM='linux/arm/v7' ;;
esac

mkdir -p "${SOURCES}"
: > "${SOURCES}/distro.tsv"
# Each named stage (FROM ... AS <name>), then the last one (the image build_static.sh built)
STAGES="$(sed -n 's/^FROM[[:space:]].*[[:space:]][Aa][Ss][[:space:]]\+\([A-Za-z0-9_.-]\+\).*/\1/p' "${DOCKERFILE}")"

for stage in ${STAGES} final; do
    image="static_builder_${APP}_${ARCH}"

    if [ "${stage}" != 'final' ]; then
        image="${image}_${stage}"

        if ! docker build -q --platform "${PLATFORM}" --target "${stage}" -f "${DOCKERFILE}" -t "${image}" \
            "static/${APP}" > /dev/null; then
            echo "Survey of ${APP}: the stage ${stage} didn't build"

            exit 1
        fi
    fi

    if ! docker run --rm --platform "${PLATFORM}" --entrypoint sh -v "$(pwd)/${OUTPUT}:/out:ro" \
        -v "$(pwd)/ci/survey_inside.sh:/survey_inside.sh:ro" "${image}" /survey_inside.sh "${stage}" \
        >> "${SOURCES}/distro.tsv"; then
        echo "Survey of ${APP}: the stage ${stage} couldn't be surveyed"

        exit 1
    fi
done

echo "Survey of ${APP}: $(wc -l < "${SOURCES}/distro.tsv") distribution packages recorded (${SOURCES}/distro.tsv)"
