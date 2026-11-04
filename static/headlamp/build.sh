#!/bin/bash

# Prepares Headlamp (a Kubernetes web UI) for the NAS: its official static server, web frontend and bundled plugins
# (copied out of its image by the Dockerfile), plus a fully static build of:
#  - headlamp_runas: switches to Headlamp's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

# Must match the image tag in amd64.Dockerfile
VERSION=0.46.0

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/headlamp/${VERSION}/${ARCH}

function check_static() {
    if ldd "$1" 2>&1 | grep -q '=>'; then
        echo "$1 isn't static"

        exit 1
    fi
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > headlamp_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: headlamp_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("headlamp_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("headlamp_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o headlamp_runas headlamp_runas.c
    strip headlamp_runas
    check_static headlamp_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_runas

    # The image (pinned by digest in the Dockerfile) is the version wanted: its server reports no version of its own
    # ("unknown"), but it must run
    /opt/headlamp/headlamp-server -version 2>&1 | grep -q '^Headlamp '
    check_static /opt/headlamp/headlamp-server

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -r /opt/headlamp/. ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/headlamp_runas ${OUTPUT_PATH}/
    ls -la ${OUTPUT_PATH} ${OUTPUT_PATH}/plugins ${OUTPUT_PATH}/static-plugins
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
