#!/bin/bash

# Prepares kvweb for the NAS: its official static program (stripped of debugging symbols - the archive's SHA256, as its
# release's checksums.txt gives it, is pinned here), plus a fully static build of:
#  - kvweb_runas: switches to kvweb's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=0.2.5
KVWEB_SHA256=79a422eff9a0d32a6be9c5a799848b275b5237b8ecb3a8fd319d1d04b2bf4372

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/kvweb/${VERSION}/${ARCH}

function build_kvweb() {
    cd ${BUILD_PATH}
    wget -q "https://github.com/natrimmer/kvweb/releases/download/v${VERSION}/kvweb_linux_amd64.tar.gz" -O kvweb.tar.gz
    echo "${KVWEB_SHA256}  kvweb.tar.gz" | sha256sum -c -
    tar -xzf kvweb.tar.gz kvweb
    strip kvweb
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > kvweb_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: kvweb_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("kvweb_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("kvweb_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o kvweb_runas kvweb_runas.c
    strip kvweb_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_kvweb
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/kvweb ${BUILD_PATH}/kvweb_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/kvweb -version
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
