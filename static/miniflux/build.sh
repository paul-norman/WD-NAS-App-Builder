#!/bin/bash

# Prepares Miniflux (an RSS / Atom feed reader) for the NAS - for the Intel models (it keeps everything in the PostgreSQL
# app, which is Intel-only): its official static program, plus a fully static build of:
#  - miniflux_runas: switches to Miniflux's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=2.3.5
# As its release publishes it (miniflux-linux-amd64.sha256)
MINIFLUX_SHA256=19cddcf53c9a052ee5c1855b4204b53719f89a51143f69f1a264388e98e08cfd

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/miniflux/${VERSION}/amd64

function build_runas() {
    cat > miniflux_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: miniflux_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("miniflux_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("miniflux_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o miniflux_runas miniflux_runas.c
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    sh /data/static/fetch.sh "https://github.com/miniflux/v2/releases/download/${VERSION}/miniflux-linux-amd64" \
        miniflux "${MINIFLUX_SHA256}"
    chmod 755 miniflux
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp miniflux miniflux_runas ${OUTPUT_PATH}/

    if ldd ${OUTPUT_PATH}/miniflux 2>&1 | grep -q '=>'; then
        echo "miniflux isn't static"

        exit 1
    fi

    # (its version written to a file first: the check reads its first line only)
    ${OUTPUT_PATH}/miniflux -version > version.txt
    grep -q "^${VERSION}$" version.txt
    # (no arguments: it says how to use it, and fails - showing that it runs)
    (${OUTPUT_PATH}/miniflux_runas 2>&1 || true) | grep -q 'Usage: miniflux_runas'
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/miniflux/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
