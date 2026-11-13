#!/bin/bash

# Prepares kvweb for the NAS - for the Intel models and the ARM ones, plus a fully static build, for each, of:
#  - kvweb_runas: switches to kvweb's own user (the NAS has no su or similar) before running it
# Intel: its official static program (stripped of debugging symbols - the archive's SHA256, as its release's
# checksums.txt gives it, is pinned here). ARM: kvweb has no release for 32-bit ARM, so it's built from the release's
# source (GitHub's archive of its tag, SHA256 pinned here) as its own release is: its web app first (pnpm, from its lock
# file), then kvweb with Go (no C parts) for ARMv7.

# The ARM models' parts are made on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked for their kernels' large memory pages (ci/check_arm_pages.py) and run
# with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=0.2.5
KVWEB_SHA256=79a422eff9a0d32a6be9c5a799848b275b5237b8ecb3a8fd319d1d04b2bf4372
KVWEB_SOURCE_SHA256=1b5253ee38a25c59a349b65afd9859f9b5bac0d503064e914831c20647105407
# The pnpm its web app is built with (the major version its own release uses)
PNPM_VERSION=10.34.9
# The architectures built (each into packages/static/kvweb/<version>/<arch>)
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

# Prepares kvweb for an architecture in the current folder, as ./kvweb: the official release for amd64, built from its
# source for armhf.
#
# $1 arch The architecture (amd64 or armhf)
function build_kvweb() {
    if [ "$1" = armhf ]; then
        build_kvweb_source

        return
    fi

    sh /data/static/fetch.sh \
        "https://github.com/natrimmer/kvweb/releases/download/v${VERSION}/kvweb_linux_amd64.tar.gz" \
        kvweb.tar.gz "${KVWEB_SHA256}"
    tar -xzf kvweb.tar.gz kvweb
    strip kvweb
}

# Builds kvweb for ARMv7 from its source in the current folder, as ./kvweb: its web app (embedded in the program), then
# kvweb itself - fully static (Go, no C parts) and stripped, with its version set as its release's is.
function build_kvweb_source() {
    local folder="${PWD}"

    sh /data/static/fetch.sh "https://github.com/natrimmer/kvweb/archive/refs/tags/v${VERSION}.tar.gz" \
        kvweb-source.tar.gz "${KVWEB_SOURCE_SHA256}"
    mkdir -p source
    tar -xzf kvweb-source.tar.gz -C source --strip-components=1

    cd source/web
    npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}"
    pnpm install --frozen-lockfile
    pnpm run build

    cd ..
    rm -rf static/dist
    cp -r web/dist static/dist
    CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath \
        -ldflags "-s -w -X main.version=${VERSION} -X main.commit=v${VERSION}" -o "${folder}/kvweb" ./cmd/kvweb
    cd "${folder}"
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > kvweb_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: kvweb_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("kvweb_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("kvweb_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o kvweb_runas kvweb_runas.c
}

# Checks an architecture's programs in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local program usage

    for program in kvweb kvweb_runas; do
        if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${program})"

            exit 1
        fi
    done

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py kvweb kvweb_runas
    run_for ${arch} ./kvweb -version | grep "kvweb ${VERSION}"
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./kvweb_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: kvweb_runas'
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
        build_kvweb ${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/kvweb/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp kvweb kvweb_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/kvweb/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
