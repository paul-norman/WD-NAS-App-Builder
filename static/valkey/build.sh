#!/bin/bash

set -e
set -o pipefail
set -x

VERSION=9.1.3
# Checked against Valkey's own published hash (github.com/valkey-io/valkey-hashes)
VALKEY_SHA256=184e34ed2d9b51879b682b5b15205e2b9d677c60280e3cb453be8f520d04e293

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH='/build'
OUTPUT_PATH="/data/packages/static/valkey/${VERSION}/${ARCH}"

function build_valkey() {
    cd ${BUILD_PATH}

    # Download
    sh /data/static/fetch.sh "https://github.com/valkey-io/valkey/archive/refs/tags/${VERSION}.tar.gz" \
        valkey.tar.gz "${VALKEY_SHA256}"
    tar -xf valkey.tar.gz --strip-components=1
    rm valkey.tar.gz

    # Not fully static: ValKey 9+ finds its built-in Lua scripting engine with dlopen(NULL), which static binaries
    # don't support. Built on Debian Bullseye instead, so the only shared libraries needed are the NAS's own glibc
    # 2.31 (libc, libm...) - everything else (Lua, jemalloc...) is still compiled in
    make -j "$(nproc)" USE_SYSTEMD=no BUILD_TLS=no
    strip src/valkey-server src/valkey-cli
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
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
