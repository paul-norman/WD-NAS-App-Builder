#!/bin/bash

set -e
set -o pipefail
set -x

VERSION=9.1.2

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH="/build"
OUTPUT_PATH="/data/packages/static/valkey/${VERSION}/${ARCH}"

function build_valkey() {
	cd ${BUILD_PATH}

	# Download
	wget "https://github.com/valkey-io/valkey/archive/refs/tags/${VERSION}.tar.gz" -O valkey.tar.gz
	tar -xf valkey.tar.gz --strip-components=1
	rm valkey.tar.gz

    make -j "$(nproc)" LDFLAGS="-s -w -static" CFLAGS="-static" USE_SYSTEMD=no BUILD_TLS=no
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_valkey
	
	# Copy to output
	mkdir -p ${OUTPUT_PATH}
	cp ${BUILD_PATH}/src/valkey-server ${OUTPUT_PATH}/.
	cp ${BUILD_PATH}/src/valkey-cli ${OUTPUT_PATH}/.
	
	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}
	
	chown -R 1000:1000 /data/packages;
}

run
