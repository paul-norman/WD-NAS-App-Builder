#!/bin/bash

# Prepares Miniflux (an RSS / Atom feed reader) for the NAS - for the Intel models and the ARM ones (it keeps everything
# in the PostgreSQL app): its official static program for each (checked against the SHA256s its release publishes,
# miniflux-linux-<arch>.sha256, pinned here), plus a fully static build of:
#  - miniflux_runas: switches to Miniflux's own user (the NAS has no su or similar) before running it

# The ARM models' parts are made on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked for their kernels' large memory pages (ci/check_arm_pages.py) and run
# with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=2.3.5
MINIFLUX_SHA256=19cddcf53c9a052ee5c1855b4204b53719f89a51143f69f1a264388e98e08cfd
MINIFLUX_ARMHF_SHA256=c5e32de2a98dd30da97c31121a0244ee0e8718a1d0012733746eb619e2103cb9
# The architectures built (each into packages/static/miniflux/<version>/<arch>)
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

# Downloads Miniflux's release for an architecture into the current folder, as ./miniflux.
#
# $1 arch The architecture (amd64 or armhf)
function build_miniflux() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/miniflux/v2/releases/download/${VERSION}/miniflux-linux-armv7" \
            miniflux "${MINIFLUX_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh \
            "https://github.com/miniflux/v2/releases/download/${VERSION}/miniflux-linux-amd64" \
            miniflux "${MINIFLUX_SHA256}"
    fi

    chmod 755 miniflux
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
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
    cc_for "$1" -o miniflux_runas miniflux_runas.c
}

# Checks an architecture's programs in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local program usage

    for program in miniflux miniflux_runas; do
        if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${program})"

            exit 1
        fi
    done

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py miniflux miniflux_runas
    # (its version written to a file first: the check reads its first line only)
    run_for ${arch} ./miniflux -version > version.txt
    grep -q "^${VERSION}$" version.txt
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./miniflux_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: miniflux_runas'
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_miniflux ${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/miniflux/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp miniflux miniflux_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/miniflux/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
