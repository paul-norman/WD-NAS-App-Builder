#!/bin/bash

# Prepares rclone for the NAS - for the Intel models and the ARM ones: its official static program for each, plus:
#  - its web interface (rclone-web), as rclone's own gui command serves it, saved as files for its remote control server
#    (rcd --rc-files) - so that the interface and the API it calls share one address (and one site in the Nginx app).
#    The interface's pages (/login, /remotes...) get a folder each with its index.html, as rcd has no fallback to it
#  - rclone_runas: switches to rclone's own user (the NAS has no su or similar) before running it, keeping the files it
#    writes group-writable (umask 002), as the NAS's shares expect
# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=1.76.0
# Each architecture's release, as its SHA256SUMS publishes it
RCLONE_SHA256=b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7
RCLONE_ARMHF_SHA256=090e1e2ce0f2a27c6c5ad5b2a2f7bbf7570933f3523e8bf83cb25ee50115f885
# The architectures built (each into packages/static/rclone/<version>/<arch>)
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

# Downloads rclone's release for an architecture into the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_rclone() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/rclone/rclone/releases/download/v${VERSION}/rclone-v${VERSION}-linux-arm-v7.zip" \
            rclone.zip "${RCLONE_ARMHF_SHA256}"
        unzip -q rclone.zip
        mv rclone-v${VERSION}-linux-arm-v7/rclone rclone
    else
        sh /data/static/fetch.sh \
            "https://github.com/rclone/rclone/releases/download/v${VERSION}/rclone-v${VERSION}-linux-amd64.zip" \
            rclone.zip "${RCLONE_SHA256}"
        unzip -q rclone.zip
        mv rclone-v${VERSION}-linux-amd64/rclone rclone
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > rclone_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program - its files writable by
// the group too (umask 002), as the NAS's shares expect
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: rclone_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("rclone_runas: could not switch user");
		return 1;
	}
	umask(002);
	execv(argv[3], &argv[3]);
	perror("rclone_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o rclone_runas rclone_runas.c
}

# Saves rclone's web interface, as its gui command serves it, into ${BUILD_PATH}/gui - its index.html and the files that
# names (its scripts name no others: checked), plus a copy of index.html for each of its pages.
function save_gui() {
    local file route

    mkdir -p ${BUILD_PATH}/gui
    ./rclone gui --no-open-browser --addr 127.0.0.1:5580 --api-addr 127.0.0.1:5581 --no-auth --config /dev/null \
        > gui.log 2>&1 &
    sleep 3
    wget -qO ${BUILD_PATH}/gui/index.html http://127.0.0.1:5580/

    for file in $(grep -oE '(src|href)="/[^"]+"' ${BUILD_PATH}/gui/index.html | sed 's/^[a-z]*="\/\(.*\)"$/\1/'); do
        mkdir -p "${BUILD_PATH}/gui/$(dirname "${file}")"
        wget -qO "${BUILD_PATH}/gui/${file}" "http://127.0.0.1:5580/${file}"
    done

    kill %1
    grep 'Serving GUI version' gui.log
    [ -s ${BUILD_PATH}/gui/assets/$(grep -oE 'assets/[^"]+\.js' ${BUILD_PATH}/gui/index.html | head -n 1 | sed 's#assets/##') ]
    ! grep -qE '"(\./|/)?assets/|import\("' ${BUILD_PATH}/gui/assets/*.js

    # Its pages: the routes without a parameter (e.g. remotes/new, not remotes/:remoteName)
    for route in $(grep -ohE 'path:"/?[a-z][a-z/]*"' ${BUILD_PATH}/gui/assets/*.js | sed 's/^path:"\/\{0,1\}\(.*\)"$/\1/' | sort -u); do
        mkdir -p "${BUILD_PATH}/gui/${route}"
        cp ${BUILD_PATH}/gui/index.html "${BUILD_PATH}/gui/${route}/"
    done

    [ -f ${BUILD_PATH}/gui/login/index.html ]
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
        build_rclone ${arch}
        build_runas ${arch}

        # The web interface (the same for every architecture): from the Intel program, which runs here
        if [ "${arch}" = amd64 ]; then
            save_gui
        fi

        output=/data/packages/static/rclone/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp rclone rclone_runas ${output}/
        cp -r ${BUILD_PATH}/gui ${output}/
        # (its version written to a file first: the check reads its first line only)
        run_for ${arch} ${output}/rclone version > version.txt
        grep -q "^rclone v${VERSION}$" version.txt
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/rclone_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: rclone_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/rclone/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
