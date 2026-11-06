#!/bin/bash

# Prepares Prometheus for the NAS - for the Intel models and the ARM ones: its official static program for each
# (stripped of debugging symbols - promtool is left out, as Prometheus checks its configuration itself, keeping the old
# one if a new one is broken), plus a fully static build of:
#  - prom_runas: switches to Prometheus' own user (the NAS has no su or similar) before running it

# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=3.15.1
# Each architecture's release, as its sha256sums.txt publishes it
PROMETHEUS_SHA256=6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84
PROMETHEUS_ARMHF_SHA256=237e87ca03537496675396e702fe2ac304103fc7d671a2c9ead30d1e639f242f
# The architectures built (each into packages/static/prometheus/<version>/<arch>)
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

# Strips a program built for an architecture of its debugging symbols.
#
# $1 arch The architecture (amd64 or armhf)
# $2 file The program
function strip_for() {
    if [ "$1" = armhf ]; then
        arm-none-eabi-strip "$2"
    else
        strip "$2"
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

# Downloads Prometheus's release for an architecture into the current folder, as ./prometheus.
#
# $1 arch The architecture (amd64 or armhf)
function build_prometheus() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/prometheus/prometheus/releases/download/v${VERSION}/prometheus-${VERSION}.linux-armv7.tar.gz" \
            prometheus.tar.gz "${PROMETHEUS_ARMHF_SHA256}"
        tar -xzf prometheus.tar.gz
        mv prometheus-${VERSION}.linux-armv7/prometheus prometheus
        strip_for armhf prometheus
    else
        sh /data/static/fetch.sh \
            "https://github.com/prometheus/prometheus/releases/download/v${VERSION}/prometheus-${VERSION}.linux-amd64.tar.gz" \
            prometheus.tar.gz "${PROMETHEUS_SHA256}"
        tar -xzf prometheus.tar.gz
        mv prometheus-${VERSION}.linux-amd64/prometheus prometheus
        strip_for amd64 prometheus
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > prom_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: prom_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("prom_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("prom_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o prom_runas prom_runas.c
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
        build_prometheus ${arch}
        build_runas ${arch}

        output=/data/packages/static/prometheus/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp prometheus prom_runas ${output}/
        run_for ${arch} ${output}/prometheus --version
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/prom_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: prom_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/prometheus/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
