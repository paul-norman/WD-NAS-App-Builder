#!/bin/bash

# Prepares mysqld_exporter for the NAS - for the Intel models and the ARM ones: its official static program for each
# (checked against the SHA256 its release publishes in sha256sums.txt, pinned here), plus a fully static build of:
#  - mysqld_exporter_runas: switches to the exporter's own user (the NAS has no su or similar) before running it

# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=0.21.0
# Each architecture's release, as its sha256sums.txt publishes it
EXPORTER_SHA256=dc38d4173ab07d1e2ec8699a3957d29d31c0b9619822cc3a451771c468f704c7
EXPORTER_ARMHF_SHA256=3682e7eb59ece468b29a9236b8a7c638e6988a2b3f64ead859902580e06df5c1
# The architectures built (each into packages/static/mysqld_exporter/<version>/<arch>)
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

# Downloads mysqld_exporter's release for an architecture into the current folder, as ./mysqld_exporter.
#
# $1 arch The architecture (amd64 or armhf)
function build_exporter() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/prometheus/mysqld_exporter/releases/download/v${VERSION}/mysqld_exporter-${VERSION}.linux-armv7.tar.gz" \
            exporter.tar.gz "${EXPORTER_ARMHF_SHA256}"
        tar -xzf exporter.tar.gz
        mv "mysqld_exporter-${VERSION}.linux-armv7/mysqld_exporter" mysqld_exporter
    else
        sh /data/static/fetch.sh \
            "https://github.com/prometheus/mysqld_exporter/releases/download/v${VERSION}/mysqld_exporter-${VERSION}.linux-amd64.tar.gz" \
            exporter.tar.gz "${EXPORTER_SHA256}"
        tar -xzf exporter.tar.gz
        mv "mysqld_exporter-${VERSION}.linux-amd64/mysqld_exporter" mysqld_exporter
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > mysqld_exporter_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: mysqld_exporter_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("mysqld_exporter_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("mysqld_exporter_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o mysqld_exporter_runas mysqld_exporter_runas.c
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
        build_exporter ${arch}
        build_runas ${arch}

        output=/data/packages/static/mysqld_exporter/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp mysqld_exporter mysqld_exporter_runas ${output}/
        run_for ${arch} ${output}/mysqld_exporter --version > version.txt 2>&1
        head -n 1 version.txt
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/mysqld_exporter_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: mysqld_exporter_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/mysqld_exporter/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
