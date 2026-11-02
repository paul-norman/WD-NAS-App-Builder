#!/bin/bash
#
# Builds a statically linked version of an app
#
# Usage:
#
#  ./build_static.sh app arch

# Always run from the repository root
cd "$(dirname "$0")" || exit 1

APP_NAME=$1
ARCH=$2

usage () {
    echo "Usage: $0 <app> <arch>"
}

if [ -z "${APP_NAME}" ]; then
    usage

    exit 1
fi

if [ "${APP_NAME}" = '-h' ]; then
    usage

    exit 0
fi

if [ -z "${ARCH}" ]; then
    usage

    exit 1
fi

if [ ! -d "static/${APP_NAME}" ]; then
    echo "No static app found named: ${APP_NAME}"

    exit 1
fi

DOCKERFILE="static/${APP_NAME}/${ARCH}.Dockerfile"

if [ ! -f "${DOCKERFILE}" ]; then
    echo "No ${ARCH} Dockerfile found: ${DOCKERFILE}"

    exit 1
fi

# The static build script detects the architecture from inside the container, so run it on the matching platform
case "${ARCH}" in
    amd64) PLATFORM='linux/amd64' ;;
    armhf) PLATFORM='linux/arm/v7' ;;
    *)
        echo "Unsupported architecture: ${ARCH}"

        exit 1
        ;;
esac

# Skip the build if this version has already been built for this architecture
VERSION="$(sed -n 's/^VERSION=//p' "static/${APP_NAME}/build.sh" | head -n 1)"

if [ -z "${VERSION}" ]; then
    echo "static/${APP_NAME}/build.sh must declare the version being built as: VERSION=<version>"

    exit 1
fi

# (unless the build script checks for its own existing outputs, e.g. when it builds several independent parts)
OUTPUT_PATH="packages/static/${APP_NAME}/${VERSION}/${ARCH}"

if ! grep -q '^CHECKS_OWN_OUTPUTS=yes' "static/${APP_NAME}/build.sh" && [ -n "$(ls -A "${OUTPUT_PATH}" 2>/dev/null)" ]; then
    echo "Static ${APP_NAME} ${VERSION} (${ARCH}) is already built: ${OUTPUT_PATH}"
    printf '%s' "${VERSION}" > "packages/static/${APP_NAME}/latest"

    exit 0
fi

# Only attach a terminal when there is one (e.g. not in CI)
DOCKER_TTY=''

if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_TTY='-it'
fi

IMAGE="static_builder_${APP_NAME}_${ARCH}"

if ! docker build --platform "${PLATFORM}" -f "${DOCKERFILE}" -t "${IMAGE}" "static/${APP_NAME}"; then
    echo "Docker container build failing!"

    exit 1
fi

# Create statically linked version of the program
if ! docker run --rm ${DOCKER_TTY} --platform "${PLATFORM}" -v "$(pwd)":/data "${IMAGE}:latest" /bin/bash -c "\
	cd /data/static/${APP_NAME};\
	/bin/bash ./build.sh;"; then
    echo "Static build of ${APP_NAME} (${ARCH}) failed!"

    exit 1
fi
