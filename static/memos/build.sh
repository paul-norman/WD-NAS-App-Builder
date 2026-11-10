#!/bin/bash

# Prepares Memos for the NAS - for the Intel models and the ARM ones: its official static program for each, plus fully
# static builds of:
#  - sqlite3: SQLite's shell, for safe backups of Memos' database while it runs
#  - memos_runas: switches to Memos' own user (the NAS has no su or similar) before running it
# The ARM models' parts are built on this (Intel) machine: the helpers cross-compiled with Zig for their ARMv7
# processors (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=26.11.0
# Each architecture's release, as its checksums.txt publishes it
MEMOS_SHA256=38b81c2bd1859555f4f7f277756541fd1ca332c94bbbee443626ace42d7b4061
MEMOS_ARMHF_SHA256=be0514dabd5b4ef311c85d1e918602d9f4b34bd7d50505b5593e411c2e2dd68a
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
# The architectures built (each into packages/static/memos/<version>/<arch>)
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

# Downloads a file, checking its SHA256 (static/fetch.sh: a kept copy, its site, then the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Downloads Memos' release for an architecture into the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_memos() {
    if [ "$1" = armhf ]; then
        fetch "https://github.com/usememos/memos/releases/download/${VERSION}/memos_${VERSION}_linux_armv7.tar.gz" \
            memos.tar.gz "${MEMOS_ARMHF_SHA256}"
    else
        fetch "https://github.com/usememos/memos/releases/download/${VERSION}/memos_${VERSION}_linux_amd64.tar.gz" \
            memos.tar.gz "${MEMOS_SHA256}"
    fi

    mkdir -p release
    tar -xzf memos.tar.gz -C release
    mv release/memos memos
}

# Builds SQLite's shell for an architecture in the current folder (as static/grafana does).
#
# $1 arch The architecture (amd64 or armhf)
function build_sqlite() {
    fetch "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip" sqlite.zip ${SQLITE_SHA256}
    unzip -q sqlite.zip
    cd sqlite-amalgamation-${SQLITE_VERSION}
    # A static binary that looks up users loads the system's own NSS libraries at run time, and crashes when their glibc
    # isn't the one it was built with (e.g. after a firmware update): its shell looks up its user's home folder only for
    # ~/.sqliterc, so that's left to $HOME - and the build stops if any such lookup is left
    sed -i 's/pwent=getpwuid(uid)/pwent=(struct passwd *)0/' shell.c

    if grep -qE '\<(getpw|getgr|gethostby|getaddrinfo|getservby)[a-z_]*\(' shell.c sqlite3.c; then
        echo "SQLite's shell looks up users or hosts: a static build would need the NAS's own NSS libraries"

        exit 1
    fi
    cc_for "$1" -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o ../sqlite3
    cd ..
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > memos_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: memos_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("memos_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("memos_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o memos_runas memos_runas.c
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
        build_memos ${arch}
        build_sqlite ${arch}
        build_runas ${arch}

        output=/data/packages/static/memos/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp memos sqlite3 memos_runas ${output}/
        [ "$(run_for ${arch} ${output}/memos --version)" = "${VERSION}" ]
        [ "$(echo 'SELECT 1;' | run_for ${arch} ${output}/sqlite3 :memory:)" = 1 ]
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/memos_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: memos_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/memos/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
