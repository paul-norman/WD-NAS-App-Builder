#!/bin/bash

# Prepares the logs app for the NAS - for the Intel models and the ARM ones: Grafana Loki (stores the logs) and Vector
# (reads the log files and sends them to Loki) - both official static programs, for each - plus a fully static build of:
#  - loki_runas: switches to Loki's own user (the NAS has no su or similar) before running it

# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=3.7.10
# Each architecture's release (as GitHub publishes their SHA256s)
LOKI_SHA256=200e74f7e631969bd0f2a066a2e1d33cdea9b3c0801aaaa7d78947c4ac29bddb
LOKI_ARMHF_SHA256=e9527d5befa77e00a3f0839cc5b7d1be44159a6e84cad7d6c8e8ab7af2721297
VECTOR_VERSION=0.61.0
VECTOR_SHA256=e1609b8a55ef1c1fc4fd88633e2bc6366e9a4022f6f1ae846cadd27af5237621
VECTOR_ARMHF_SHA256=c1fc73646ede49c0db1e03a0414abf9e8b0afe1a935f200619d7c23b3cbcddf1
# The architectures built (each into packages/static/loki/<version>/<arch>)
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

# Downloads Loki's and Vector's releases for an architecture into the current folder, as ./loki and ./vector.
#
# $1 arch The architecture (amd64 or armhf)
function build_programs() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/grafana/loki/releases/download/v${VERSION}/loki-linux-arm.zip" \
            loki.zip "${LOKI_ARMHF_SHA256}"
        unzip -q loki.zip
        mv loki-linux-arm loki
        sh /data/static/fetch.sh \
            "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-armv7-unknown-linux-musleabihf.tar.gz" \
            vector.tar.gz "${VECTOR_ARMHF_SHA256}"
        tar -xzf vector.tar.gz
        mv vector-armv7-unknown-linux-musleabihf/bin/vector vector
    else
        sh /data/static/fetch.sh \
            "https://github.com/grafana/loki/releases/download/v${VERSION}/loki-linux-amd64.zip" \
            loki.zip "${LOKI_SHA256}"
        unzip -q loki.zip
        mv loki-linux-amd64 loki
        sh /data/static/fetch.sh \
            "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
            vector.tar.gz "${VECTOR_SHA256}"
        tar -xzf vector.tar.gz
        mv vector-x86_64-unknown-linux-musl/bin/vector vector
    fi

    chmod 755 loki
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > loki_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: loki_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("loki_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("loki_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o loki_runas loki_runas.c
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
        build_programs ${arch}
        build_runas ${arch}

        output=/data/packages/static/loki/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp loki vector loki_runas ${output}/
        run_for ${arch} ${output}/loki --version > version.txt
        head -n 1 version.txt
        run_for ${arch} ${output}/vector --version
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/loki_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: loki_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/loki/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
