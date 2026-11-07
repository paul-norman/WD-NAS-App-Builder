#!/bin/bash

# Prepares the template app's program for the NAS - for the Intel models and the ARM ones. The template's example is
# miniserve (a small web server for a folder): its official static release for each (checked against the SHA256 pinned
# here), plus a fully static build of:
#  - template_runas: switches to the app's own user (the NAS has no su or similar) before running it
# A new app replaces miniserve with its own program (download it, or build it) and renames the helper.

# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=0.35.0
# Each architecture's release (GitHub's digest of each file, on the release page)
MINISERVE_SHA256=c630ee030d5d9d83c88c5cc72f43ae215b0c214d64fd7afc92244fe369af2964
MINISERVE_ARMHF_SHA256=0be26e48d8d7b4f2a9019b30c9eae1a1054c482989ec41024025bd9f54f9c8ff
# The architectures built (each into packages/static/template/<version>/<arch>)
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

# Downloads miniserve's release for an architecture into the current folder, as ./miniserve.
#
# $1 arch The architecture (amd64 or armhf)
function build_miniserve() {
    local base="https://github.com/svenstaro/miniserve/releases/download/v${VERSION}/miniserve-${VERSION}"

    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh "${base}-armv7-unknown-linux-musleabihf" miniserve "${MINISERVE_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh "${base}-x86_64-unknown-linux-musl" miniserve "${MINISERVE_SHA256}"
    fi

    chmod 755 miniserve
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > template_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: template_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("template_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("template_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o template_runas template_runas.c
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
        build_miniserve ${arch}
        build_runas ${arch}

        output=/data/packages/static/template/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp miniserve template_runas ${output}/
        run_for ${arch} ${output}/miniserve --version | grep -q "miniserve ${VERSION}"
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/template_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: template_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/template/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
