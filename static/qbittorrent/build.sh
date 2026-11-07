#!/bin/bash

# Prepares qBittorrent (its headless qbittorrent-nox) for the NAS - for the Intel models and the ARM ones: the fully
# static program qbittorrent-nox-static publishes for each (Qt 6, libtorrent, Boost, OpenSSL and zlib linked in), plus:
#  - qbt_runas: switches to qBittorrent's own user (the NAS has no su or similar) before running it, keeping the files
#    it writes group-writable (umask 002), as the NAS's shares expect
#  - ca-certificates.crt: the certificate authorities, for its HTTPS trackers, RSS feeds and searches (the NAS's own
#    list may be old or missing)
# The ARM models' parts are built on this (Intel) machine: the helper cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=5.3.0
# The libtorrent line its releases are named after (release-<qBittorrent>_v<libtorrent>)
LIBTORRENT_VERSION=2.1.2
# Qt's version in that release (its dependency-version.json says it): its source is listed for the app's releases (Qt is
# LGPL), so the build stops if they differ
QT_VERSION=6.12.0
# Each architecture's program, and the release's list of what it contains, as GitHub publishes their digests
QBT_SHA256=563e695a2b830e62e627e1ae403bcfcc494e444d5cabb5ecc1e09907353d8ed5
QBT_ARMHF_SHA256=4685ecf166aba167b609c6d592c3ef21d97e8dea186648da1c54d2e064ceebd5
DEPENDENCIES_SHA256=3f15cfe4ebda4ada305fb7e7776bebf302e0a655d9ab980bcf31d0b70f43f1e8
# The architectures built (each into packages/static/qbittorrent/<version>/<arch>)
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

# Downloads qbittorrent-nox for an architecture into the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_qbittorrent() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-${VERSION}_v${LIBTORRENT_VERSION}/armv7-qbittorrent-nox" \
            qbittorrent-nox "${QBT_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh \
            "https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-${VERSION}_v${LIBTORRENT_VERSION}/x86_64-qbittorrent-nox" \
            qbittorrent-nox "${QBT_SHA256}"
    fi

    chmod 755 qbittorrent-nox
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > qbt_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program - its files writable by
// the group too (umask 002), as the NAS's shares expect
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: qbt_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("qbt_runas: could not switch user");
		return 1;
	}
	umask(002);
	execv(argv[3], &argv[3]);
	perror("qbt_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o qbt_runas qbt_runas.c
}

function run() {
    local arch output usage qt

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    # The release's own list of its parts: Qt's version must be the one whose source the app's releases list
    sh /data/static/fetch.sh \
        "https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-${VERSION}_v${LIBTORRENT_VERSION}/dependency-version.json" \
        dependency-version.json "${DEPENDENCIES_SHA256}"
    qt="$(sed -n 's/^ *"qt6": *"\([^"]*\)".*/\1/p' dependency-version.json)"

    if [ "${qt}" != "${QT_VERSION}" ]; then
        echo "This release has Qt ${qt}: set QT_VERSION=${qt} (its source is listed in ci/sources/qbittorrent.conf)" >&2

        exit 1
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_qbittorrent ${arch}
        build_runas ${arch}

        output=/data/packages/static/qbittorrent/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp qbittorrent-nox qbt_runas /etc/ssl/certs/ca-certificates.crt ${output}/
        cp ${BUILD_PATH}/dependency-version.json ${output}/
        # (its version written to a file first: the check reads its first line only)
        run_for ${arch} ${output}/qbittorrent-nox --version > version.txt
        grep -q "^qBittorrent v${VERSION}" version.txt
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/qbt_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: qbt_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/qbittorrent/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
