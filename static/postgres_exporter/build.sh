#!/bin/bash

# Prepares postgres_exporter for the NAS - for the Intel models and the ARM ones: its official static program for each
# (checked against the SHA256s its release publishes in sha256sums.txt, pinned here), plus a fully static build of:
#  - postgres_exporter_runas: switches to the exporter's own user (the NAS has no su or similar) before running it

# The ARM models' parts are made on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked for their kernels' large memory pages (ci/check_arm_pages.py) and run
# with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=0.20.1
EXPORTER_SHA256=89d4f7e7920cad48fdc3133f789556ef5253c330a9f5fdace3bdb6344c0a8b5a
EXPORTER_ARMHF_SHA256=97ad243f87ecb231e205713292329ae9ca1bbe9400f45a31f685a5f353d130c4
# The architectures built (each into packages/static/postgres_exporter/<version>/<arch>)
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

# Downloads the exporter's release for an architecture into the current folder, as ./postgres_exporter.
#
# $1 arch The architecture (amd64 or armhf)
function build_exporter() {
    local name="postgres_exporter-${VERSION}.linux-amd64"

    if [ "$1" = armhf ]; then
        name="postgres_exporter-${VERSION}.linux-armv7"
        sh /data/static/fetch.sh \
            "https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}/postgres_exporter-${VERSION}.linux-armv7.tar.gz" \
            exporter.tar.gz "${EXPORTER_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh \
            "https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}/postgres_exporter-${VERSION}.linux-amd64.tar.gz" \
            exporter.tar.gz "${EXPORTER_SHA256}"
    fi

    tar -xzf exporter.tar.gz
    mv "${name}/postgres_exporter" postgres_exporter
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > postgres_exporter_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: postgres_exporter_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("postgres_exporter_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("postgres_exporter_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o postgres_exporter_runas postgres_exporter_runas.c
}

# Checks an architecture's programs in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local program usage

    for program in postgres_exporter postgres_exporter_runas; do
        if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${program})"

            exit 1
        fi
    done

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py postgres_exporter postgres_exporter_runas
    run_for ${arch} ./postgres_exporter --version 2>&1 | grep "${VERSION}"
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./postgres_exporter_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: postgres_exporter_runas'
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
        build_exporter ${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/postgres_exporter/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp postgres_exporter postgres_exporter_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/postgres_exporter/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
