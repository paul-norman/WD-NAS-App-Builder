#!/bin/bash
#
# Builds a package and optionally installs it on a target host platform
#
# Usage:
#
#  ./build.sh <package> [<host> <model> <version>]

# Always run from the repository root
cd "$(dirname "$0")" || exit 1

APP_NAME=$1

usage () {
    echo "Usage: $0 <package> [<host> <model> <version>]"
}

if [ -z "$1" ]; then
    usage

    exit 1
fi

if [ "$1" = '-h' ]; then
    usage

    exit 0
fi

if [ ! -d "apps/${APP_NAME}" ]; then
    echo "No app found named: ${APP_NAME}"

    exit 1
fi

# Only attach a terminal when there is one (e.g. not in CI)
DOCKER_TTY=''

if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_TTY='-it'
fi

# Build any statically linked binaries first if required
if [ -d "static/${APP_NAME}" ]; then
    /bin/bash build_static.sh "${APP_NAME}" amd64 || exit 1
    #/bin/bash build_static.sh "${APP_NAME}" armhf || exit 1
fi

# Build the builder image (cached layers make this quick when the Dockerfile is unchanged)
# mksapkg-OS5 is an x86-64 binary, so the builder always runs as amd64
if ! docker build --platform linux/amd64 -f docker/build.Dockerfile -t wd_builder docker; then
    echo "Docker container build failing!"

    exit 1
fi

# Create packages for app (output ownership is handed back even if the build fails)
docker run --rm ${DOCKER_TTY} --platform linux/amd64 -e MODEL_OVERRIDE -v "$(pwd)":/data wd_builder:latest /bin/bash -c "\
	cd /data;\
	find -type f -name \"*.sh\" -exec chmod +x {} +;\
	find -type f -name \"*.rc\" -exec chmod +x {} +;\
	cd /data/apps/${APP_NAME};\
	./build.sh;\
	status=\$?;\
	chown -R $(id -u):$(id -g) ../../packages/;\
	exit \$status;"
if [ $? -ne 0 ]; then
    echo "Building ${APP_NAME} failed!"

    exit 1
fi

# Deploy to a host machine
HOST="$2"

if [ -z "${HOST}" ]; then
    exit 0
fi

echo -e "\nDeploying to Host: ${HOST}"
echo "App: ${APP_NAME}"

# Get the model
MODEL="$3"

if [ -z "${MODEL}" ]; then
    MODEL='MyCloudPR4100'
fi
echo "Model: ${MODEL}"

# Get the version
VERSION="$4"

if [ -z "${VERSION}" ]; then
    VERSION="$(cat packages/${APP_NAME}/latest)"
fi
echo "Version: ${VERSION}"

# Find latest package
BINARY=$(find packages/${APP_NAME}/${VERSION} -name "*${APP_NAME}_*_${MODEL}.bin" | sort | tail -n1)
echo "Package: ${BINARY}"

echo 'Deployment to host has not yet been investigated / tested'

exit 1


echo -e "\nUploading the app binary via SCP"
scp ${BINARY} ${HOST}:/shares/Volume_1/.systemfile/upload/app.bin

#cssh='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
cssh=ssh

echo 'Installing using upload_apkg'
ALREADY_INSTALLED=$($cssh ${HOST} "del_apkg whatever | grep ${APP_NAME}")

if [ -z "${ALREADY_INSTALLED}" ]; then
    ${cssh} ${HOST} "PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin /usr/sbin/upload_apkg -rapp.bin -d -f1 -g1 && echo 'SUCCESS!'"
else
    echo 'ALREADY INSTALLED'
    echo "(Warning: this usually doesn't work!)"
    ${cssh} ${HOST} "PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin /usr/sbin/upload_apkg -m -papp.bin -t2  && echo 'SUCCESS!'"
fi

# Run any tests
TEST=tests/${APP_NAME}/test.sh

if [ -e ${TEST} ]; then
    echo -e "\nRunning tests"
    export PACKAGE=${APP_NAME}
    export TARGET=${HOST}
    ${TEST}
else
    echo -e "\nNo tests found for ${APP_NAME}... skipping"
fi
