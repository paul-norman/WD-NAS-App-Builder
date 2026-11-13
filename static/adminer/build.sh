#!/bin/bash

# Prepares Adminer for the NAS - for the Intel models and the ARM ones: its official single PHP file (every driver and
# language) and its Redis driver plugin (for the Valkey app - as released on adminer.org: the repository's own copy only
# works with Adminer's development version). Neither has published checksums, so their SHA256s are pinned here. Plus a
# fully static build, for each architecture, of:
#  - adminer_runas: switches to Adminer's own user (the NAS has no su or similar) before running PHP's server

# The ARM models' helper is cross-compiled on this (Intel) machine with Zig for their ARMv7 processors (hard-float), and
# checked for their kernels' large memory pages (ci/check_arm_pages.py) and run with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=6.3.0
ADMINER_SHA256=641e1a31e8cc333a309e202ef9446e1fd38c2069ed5f9ee509b80d70089d0503
REDIS_DRIVER_SHA256=2ef139ba8dffc915bf0116c15da3f6c9cdcec8094f519a2d09adb17077aee623
# The architectures built (each into packages/static/adminer/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

# Compiles a fully static C program for an architecture (stripped): gcc for amd64, Zig for armhf.
#
# $1 arch The architecture (amd64 or armhf)
# $@      The compiler's other arguments
function cc_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s "$@"
    else
        gcc -O2 -static -s "$@"
    fi
}

# Runs a program built for an architecture here (an ARM one with QEMU's emulator, as a Cortex-A9 - the ARM models'
# processors' kind).
#
# $1 arch The architecture (amd64 or armhf)
# $@      The program and its arguments
function run_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 "$@"
    else
        "$@"
    fi
}

# Downloads Adminer and its Redis driver into ${BUILD_PATH} (the same files for every architecture).
function build_adminer() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://github.com/vrana/adminer/releases/download/v${VERSION}/adminer-${VERSION}.php" \
        adminer.php "${ADMINER_SHA256}"
    mkdir -p adminer-plugins
    sh /data/static/fetch.sh "https://www.adminer.org/static/download/${VERSION}/drivers/redis.php" \
        adminer-plugins/redis.php "${REDIS_DRIVER_SHA256}"
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
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
    cc_for "$1" -o adminer_runas adminer_runas.c
}

# Checks an architecture's helper in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local usage

    if ! file adminer_runas | grep -E 'statically linked|static-pie linked' > /dev/null; then
        echo "adminer_runas (${arch}) isn't static: $(file adminer_runas)"

        exit 1
    fi

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py adminer_runas
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./adminer_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: adminer_runas'
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}
    build_adminer
    head -n 3 ${BUILD_PATH}/adminer.php

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/adminer/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp -r ${BUILD_PATH}/adminer.php ${BUILD_PATH}/adminer-plugins adminer_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/adminer/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
