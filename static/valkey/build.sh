#!/bin/bash

set -e
set -o pipefail
set -x

VALKEY_VERSION=8.0.1

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH="/build"
OUTPUT_PATH="/data/packages/static/valkey/${VALKEY_VERSION}/${ARCH}"

function build_valkey() {
	cd ${BUILD_PATH}

	# Download
	wget "https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz" -O valkey.tar.gz
	tar -xf valkey.tar.gz --strip-components=1
	rm valkey.tar.gz

    sed -i "s|\(protected_mode.*\)1|\10|g" src/config.c
	
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
	printf "%s" "${VALKEY_VERSION}" > ${LATEST_PATH}
	
	chown -R 1000:1000 /data/packages;
}

run