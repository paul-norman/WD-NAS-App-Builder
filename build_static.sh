#!/bin/bash
#
# Builds a statically linked version of a program
#
# Usage:
#
#  ./build_static.sh program

PROGRAM_NAME=$1

usage () {
	echo "Usage: $0 <program>"
}

if [ -z "${PROGRAM_NAME}" ]; then
	usage
	exit 1
fi

if [ "${PROGRAM_NAME}" = "-h" ]; then
	usage
	exit 0
fi

# TODO: Only AMD64 supported
if [[ "$(docker images -q static_builder_${PROGRAM_NAME}:latest 2> /dev/null)" == "" ]]; then
	docker build -f docker/static_amd64.Dockerfile -t static_builder_${PROGRAM_NAME} .
fi

# Create statically linked version of the program
if [[ "$(docker images -q static_builder_${PROGRAM_NAME}:latest 2> /dev/null)" != "" ]]; then
	docker run -it -v $(pwd):/data static_builder_${PROGRAM_NAME}:latest /bin/bash -c "\
	cd /data;\
	find -type f -name \"*.sh\" -exec chmod +x {} +;\
	cd /data/static/${PROGRAM_NAME};\
	./build.sh;"
else
	echo "Docker container build failing!"
fi