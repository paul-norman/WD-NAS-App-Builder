#!/bin/bash

# Prepares ntfy for the NAS - for the Intel models and the ARM ones: its official static program for each, plus a fully
# static build of:
#  - ntfy_runas: switches to ntfy's own user (the NAS has no su or similar) before running it
# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=2.37.2
# Each architecture's release, as its checksums.txt publishes it
NTFY_SHA256=e67f53d7fbed529b83faf3993b584110921ef3567b0ac0b033c6910879a4ffd1
NTFY_ARMHF_SHA256=51d59c18f2dc2976f6a446a9dbf4aebc814a31de299210c4757400a80d52576b
# The architectures built (each into packages/static/ntfy/<version>/<arch>)
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

# Downloads ntfy's release for an architecture into the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_ntfy() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/binwiederhier/ntfy/releases/download/v${VERSION}/ntfy_${VERSION}_linux_armv7.tar.gz" \
            ntfy.tar.gz "${NTFY_ARMHF_SHA256}"
        tar -xzf ntfy.tar.gz
        mv ntfy_${VERSION}_linux_armv7/ntfy ntfy
    else
        sh /data/static/fetch.sh \
            "https://github.com/binwiederhier/ntfy/releases/download/v${VERSION}/ntfy_${VERSION}_linux_amd64.tar.gz" \
            ntfy.tar.gz "${NTFY_SHA256}"
        tar -xzf ntfy.tar.gz
        mv ntfy_${VERSION}_linux_amd64/ntfy ntfy
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > ntfy_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: ntfy_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("ntfy_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("ntfy_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o ntfy_runas ntfy_runas.c
}

function run() {
    local arch output usage

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_ntfy ${arch}
        build_runas ${arch}

        output=/data/packages/static/ntfy/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp ntfy ntfy_runas ${output}/
        run_for ${arch} ${output}/ntfy --help > /dev/null
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/ntfy_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: ntfy_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/ntfy/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
