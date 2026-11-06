#!/bin/bash

# Prepares pgweb for the NAS - for the Intel models and the ARM ones: its official static program for each (its release
# publishes no checksums, so the archive's SHA256 is pinned here), plus a fully static build of:
#  - pgweb_runas: switches to pgweb's own user (the NAS has no su or similar) before running it

# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=0.17.0
# Each architecture's release (it publishes no checksums: these are GitHub's, of each archive)
PGWEB_SHA256=042b70755a0ad0443ff91fe1116b89472da3b841122064942d8024297d4af9ad
PGWEB_ARMHF_SHA256=e2951e02d9248cf44c687b919d8ba9865f2b3aa7051b2cb40fadd67867e1d79e
# The architectures built (each into packages/static/pgweb/<version>/<arch>)
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

# Downloads pgweb's release for an architecture into the current folder, as ./pgweb.
#
# $1 arch The architecture (amd64 or armhf)
function build_pgweb() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/sosedoff/pgweb/releases/download/v${VERSION}/pgweb_linux_arm_v5.zip" \
            pgweb.zip "${PGWEB_ARMHF_SHA256}"
        unzip -q pgweb.zip
        mv pgweb_linux_arm_v5 pgweb
    else
        sh /data/static/fetch.sh \
            "https://github.com/sosedoff/pgweb/releases/download/v${VERSION}/pgweb_linux_amd64.zip" \
            pgweb.zip "${PGWEB_SHA256}"
        unzip -q pgweb.zip
        mv pgweb_linux_amd64 pgweb
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
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
    cc_for "$1" -o pgweb_runas pgweb_runas.c
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
        build_pgweb ${arch}
        build_runas ${arch}

        output=/data/packages/static/pgweb/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp pgweb pgweb_runas ${output}/
        run_for ${arch} ${output}/pgweb --version
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/pgweb_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: pgweb_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/pgweb/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
