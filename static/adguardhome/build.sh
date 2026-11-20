#!/bin/bash

# Prepares AdGuard Home for the NAS - for the Intel models and the ARM ones: its official static program (each
# architecture's release archive, its SHA256 as its release publishes it, pinned here), plus a fully static build, for
# each, of:
#  - adguardhome_runas: switches to AdGuard Home's own user (the NAS has no su or similar) before running it
#
# The ARM models' parts are checked on this (Intel) machine: AdGuard Home's ARMv7 program and the helper (cross-compiled
# with Zig for their ARMv7 processors) for their kernels' large memory pages (ci/check_arm_pages.py), and run with
# QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=1.0.0
# As its release publishes them
ADGUARDHOME_SHA256=19e023d98eb42eb1cdbfd6e4b6ebc937dade59e969506c62eafb3a3d6d2c1e4f
ADGUARDHOME_ARMHF_SHA256=7daac1e31ad5b244dd2bb87dca686f55a291156b2ea0477041acdf2cf3b23165
# The architectures built (each into packages/static/adguardhome/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

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

# Puts AdGuard Home's release for an architecture into the current folder, as ./AdGuardHome (and its license).
#
# $1 arch The architecture (amd64 or armhf)
function build_adguardhome() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${VERSION}/AdGuardHome_linux_armv7.tar.gz" \
            adguardhome.tar.gz "${ADGUARDHOME_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh \
            "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${VERSION}/AdGuardHome_linux_amd64.tar.gz" \
            adguardhome.tar.gz "${ADGUARDHOME_SHA256}"
    fi

    # (its archive's folder has the program's name)
    mkdir -p release
    tar -xzf adguardhome.tar.gz -C release
    mv release/AdGuardHome/AdGuardHome release/AdGuardHome/LICENSE.txt .
    rm -rf release adguardhome.tar.gz
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > adguardhome_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: adguardhome_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("adguardhome_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("adguardhome_runas: could not run the program");
	return 127;
}
C
    if [ "$1" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s -o adguardhome_runas adguardhome_runas.c
    else
        gcc -O2 -static -s -o adguardhome_runas adguardhome_runas.c
    fi

    rm adguardhome_runas.c
}

# Checks an architecture's programs in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local program usage

    for program in AdGuardHome adguardhome_runas; do
        if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${program})"

            exit 1
        fi
    done

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py AdGuardHome adguardhome_runas
    run_for ${arch} ./AdGuardHome --version | grep "v${VERSION}"
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./adguardhome_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: adguardhome_runas'
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
        build_adguardhome ${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/adguardhome/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp AdGuardHome LICENSE.txt adguardhome_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/adguardhome/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
