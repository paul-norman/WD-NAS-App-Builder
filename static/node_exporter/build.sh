#!/bin/bash

# The tools the Node Exporter app uses alongside Node Exporter (which is downloaded by the app's own build.sh):
#  - smartctl: smartmontools' SMART tool, fully static, for the disks' SMART health and attributes (with its built-in
#    drive database, which names each drive model's attributes)

set -e
set -o pipefail
set -x

# The app's version (Node Exporter's), which this is built for
VERSION=1.12.1
SMARTMONTOOLS_VERSION=7.5
# (smartmontools publishes MD5s: 38c38b0b82db7fc4906cdd50d15a7931 - checked to match)
SMARTMONTOOLS_SHA256=690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/node_exporter/${VERSION}/${ARCH}

function build_smartctl() {
	cd ${BUILD_PATH}
	wget -q "https://github.com/smartmontools/smartmontools/releases/download/RELEASE_${SMARTMONTOOLS_VERSION//./_}/smartmontools-${SMARTMONTOOLS_VERSION}.tar.gz" -O smartmontools.tar.gz
	echo "${SMARTMONTOOLS_SHA256}  smartmontools.tar.gz" | sha256sum -c -
	tar -xzf smartmontools.tar.gz
	cd smartmontools-${SMARTMONTOOLS_VERSION}
	./configure LDFLAGS=-static --without-libsystemd --without-systemdsystemunitdir --without-selinux --without-libcap-ng
	make -j "$(nproc)" smartctl
	strip smartctl
	if ldd smartctl 2>&1 | grep -q "=>"; then
		echo "smartctl isn't static"
		exit 1
	fi
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_smartctl

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}
	cp ${BUILD_PATH}/smartmontools-${SMARTMONTOOLS_VERSION}/smartctl ${OUTPUT_PATH}/
	${OUTPUT_PATH}/smartctl --version | head -n 1
	du -sh ${OUTPUT_PATH}

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
