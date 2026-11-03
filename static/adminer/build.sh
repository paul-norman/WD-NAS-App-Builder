#!/bin/bash

# Prepares Adminer for the NAS: its official single PHP file (every driver and language) and its Redis driver plugin
# (for the Valkey app - as released on adminer.org: the repository's own copy only works with Adminer's development
# version). Neither has published checksums, so their SHA256s are pinned here. Plus a fully static build of:
#  - adminer_runas: switches to Adminer's own user (the NAS has no su or similar) before running PHP's server

set -e
set -o pipefail
set -x

VERSION=6.2.0
ADMINER_SHA256=9047c00dfc8258c6046c6720d7d201eaa0ca016fa0fc554bf0c4c137306e1c16
REDIS_DRIVER_SHA256=926581a27d3e700fb51ba4c3ac192061b8f57640d562de7ef0d9c2df6dfd34f8

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/adminer/${VERSION}/${ARCH}

function build_adminer() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://github.com/vrana/adminer/releases/download/v${VERSION}/adminer-${VERSION}.php" \
        adminer.php "${ADMINER_SHA256}"
    mkdir -p adminer-plugins
    sh /data/static/fetch.sh "https://www.adminer.org/static/download/${VERSION}/drivers/redis.php" \
        adminer-plugins/redis.php "${REDIS_DRIVER_SHA256}"
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > adminer_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: adminer_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("adminer_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("adminer_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o adminer_runas adminer_runas.c
    strip adminer_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_adminer
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -r ${BUILD_PATH}/adminer.php ${BUILD_PATH}/adminer-plugins ${BUILD_PATH}/adminer_runas ${OUTPUT_PATH}/
    head -n 3 ${OUTPUT_PATH}/adminer.php
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
