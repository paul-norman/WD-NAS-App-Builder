#!/bin/bash
#
# Builds a statically linked version of an app
#
# Usage:
#
#  ./build_static.sh app arch

APP_NAME=$1
ARCH=$2

usage () {
	echo "Usage: $0 <app> <arch>"
}

if [ -z "${APP_NAME}" ]; then
	usage
	exit 1
fi

if [ "${APP_NAME}" = "-h" ]; then
	usage
	exit 0
fi

if [ -z "${ARCH}" ]; then
	usage
	exit 1
fi

# Build the statically linked binary if it doesn't already exist
if [ -d "static/${APP_NAME}" ] && [ ! -d "packages/static/${APP_NAME}" ]; then
	# TODO: Only AMD64 supported
	if [[ "$(docker images -q static_builder_${APP_NAME}_${ARCH}:latest 2> /dev/null)" == "" ]]; then
		docker build -f static/${APP_NAME}/${ARCH}.Dockerfile -t static_builder_${APP_NAME}_${ARCH} .
	fi

	# Create statically linked version of the program
	if [[ "$(docker images -q static_builder_${APP_NAME}_${ARCH}:latest 2> /dev/null)" != "" ]]; then
		docker run -it -v $(pwd):/data static_builder_${APP_NAME}_${ARCH}:latest /bin/bash -c "\
		cd /data;\
		find -type f -name \"*.sh\" -exec chmod +x {} +;\
		cd /data/static/${APP_NAME};\
		./build.sh;"
	else
		echo "Docker container build failing!"
	fi
fi