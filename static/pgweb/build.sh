#!/bin/bash

# Prepares pgweb for the NAS: its official static program (its release publishes no checksums, so the archive's SHA256
# is pinned here), plus a fully static build of:
#  - pgweb_runas: switches to pgweb's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=0.17.0
PGWEB_SHA256=042b70755a0ad0443ff91fe1116b89472da3b841122064942d8024297d4af9ad

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/pgweb/${VERSION}/${ARCH}

function build_pgweb() {
    cd ${BUILD_PATH}
    wget -q "https://github.com/sosedoff/pgweb/releases/download/v${VERSION}/pgweb_linux_amd64.zip" -O pgweb.zip
    echo "${PGWEB_SHA256}  pgweb.zip" | sha256sum -c -
    unzip -q pgweb.zip
    mv pgweb_linux_amd64 pgweb
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > pgweb_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: pgweb_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("pgweb_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("pgweb_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o pgweb_runas pgweb_runas.c
    strip pgweb_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_pgweb
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/pgweb ${BUILD_PATH}/pgweb_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/pgweb --version
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
