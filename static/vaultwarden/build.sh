#!/bin/bash

# Prepares Vaultwarden for the NAS - for the Intel models and the ARM ones: its static program and web vault (copied out
# of the images the Dockerfile makes: Vaultwarden's official one for the Intel models, built from its source for the ARM
# ones), plus fully static builds, for each, of the tools the app uses alongside it:
#  - sqlite3: SQLite's shell, for safe backups of the database while Vaultwarden runs
#  - argon2:  the reference Argon2 tool, which hashes the admin token the way Vaultwarden's documentation does
#  - vw_runas: switches to Vaultwarden's own user (the NAS has no su or similar) before running it

# The ARM models' tools are cross-compiled on this (Intel) machine with Zig for their ARMv7 processors (hard-float), and
# every ARM program is checked for their kernels' large memory pages (ci/check_arm_pages.py) and run with QEMU's
# emulator - Vaultwarden itself started, answering on its health check.

set -e
set -o pipefail
set -x

# Must match the image tag (and the ARM build's version) in amd64.Dockerfile
VERSION=1.37.5
# The web vault in that image (vault_version in Vaultwarden's docker/DockerSettings.yaml at its tag): checked below, and
# used for its source (ci/sources/vaultwarden.conf). The same for both architectures
WEB_VAULT_VERSION=2026.10.1
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
ARGON2_VERSION=20190702
ARGON2_SHA256=daf972a89577f8772602bf2eb38b6a3dd3d922bf5724d45e7f9589b5e830442c
# The architectures built (each into packages/static/vaultwarden/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

# Compiles a fully static C program for an architecture: gcc for amd64, Zig for armhf.
#
# $1 arch The architecture (amd64 or armhf)
# $@      The compiler's other arguments
function cc_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 "$@"
    else
        gcc "$@"
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

# Strips a program built for an architecture.
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

# Downloads a file into ${BUILD_PATH} and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Builds SQLite's shell for an architecture into ${BUILD_PATH}/<arch>/sqlite3.
#
# $1 arch The architecture (amd64 or armhf)
function build_sqlite() {
    cd ${BUILD_PATH}/$1
    unzip -q ${BUILD_PATH}/sqlite.zip
    cd sqlite-amalgamation-${SQLITE_VERSION}
    cc_for "$1" -O2 -static -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c \
        -o ${BUILD_PATH}/$1/sqlite3
    strip_for "$1" ${BUILD_PATH}/$1/sqlite3
}

# Builds the Argon2 tool for an architecture into ${BUILD_PATH}/<arch>/argon2: for a generic Intel processor (the
# default, native, would tune it to the build machine's), or with its portable code for ARM (its optimised code is for
# Intel's SSE).
#
# $1 arch The architecture (amd64 or armhf)
function build_argon2() {
    cd ${BUILD_PATH}/$1
    tar -xzf ${BUILD_PATH}/argon2.tar.gz
    cd phc-winner-argon2-${ARGON2_VERSION}

    if [ "$1" = armhf ]; then
        make argon2 CC='zig cc -target arm-linux-musleabihf -mcpu=cortex_a9' NO_OPT=1 LDFLAGS='-static -pthread'
    else
        make argon2 OPTTARGET=x86-64 LDFLAGS='-static -pthread'
    fi

    cp argon2 ${BUILD_PATH}/$1/argon2
    strip_for "$1" ${BUILD_PATH}/$1/argon2
}

# Builds the run-as helper for an architecture into ${BUILD_PATH}/<arch>/vw_runas.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cd ${BUILD_PATH}/$1
    cat > vw_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: vw_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("vw_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("vw_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -O2 -static -o vw_runas vw_runas.c
    strip_for "$1" vw_runas
}

# Checks an architecture's output folder: every program static (the ARM ones laid out for large memory pages) and
# running, Vaultwarden the version being packaged - started on a new database, answering its health check.
#
# $1 arch   The architecture (amd64 or armhf)
# $2 output The output folder
function check() {
    local arch="$1"
    local output="$2"
    local program usage pid i port
    local emulator=''

    for program in vaultwarden sqlite3 argon2 vw_runas; do
        if ! file ${output}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${output}/${program})"

            exit 1
        fi
    done

    if [ "${arch}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${output}/vaultwarden ${output}/sqlite3 ${output}/argon2 ${output}/vw_runas
    fi

    run_for ${arch} ${output}/vaultwarden --version > ${BUILD_PATH}/version.txt
    grep "^Vaultwarden ${VERSION}$" ${BUILD_PATH}/version.txt > /dev/null
    run_for ${arch} ${output}/sqlite3 --version
    echo -n 'password' | run_for ${arch} ${output}/argon2 somesaltvalue -id -e | grep '^\$argon2id\$' > /dev/null
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ${output}/vw_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: vw_runas' > /dev/null

    # (started directly - not through run_for - so that it's the process stopped afterwards; on a port of its own)
    port=18080

    if [ "${arch}" = armhf ]; then
        emulator='qemu-arm -cpu cortex-a9'
        port=18081
    fi

    rm -rf /tmp/vw-test
    mkdir -p /tmp/vw-test
    DATA_FOLDER=/tmp/vw-test WEB_VAULT_FOLDER=${output}/web-vault ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=${port} \
        ${emulator} ${output}/vaultwarden > /tmp/vw-test/vaultwarden.log 2>&1 &
    pid=$!

    for i in $(seq 1 90); do
        wget -q -O /tmp/vw-test/alive http://127.0.0.1:${port}/alive 2>/dev/null && break
        sleep 1
    done

    kill ${pid} 2>/dev/null || true
    wait ${pid} 2>/dev/null || true

    if [ ! -s /tmp/vw-test/alive ] || [ ! -f /tmp/vw-test/db.sqlite3 ]; then
        echo "Vaultwarden (${arch}) didn't answer its health check:"
        cat /tmp/vw-test/vaultwarden.log

        exit 1
    fi
}

function run() {
    local arch output program

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    # The image's web vault must be the version being packaged
    if ! grep -q "\"${WEB_VAULT_VERSION}\"" /opt/vaultwarden/web-vault/version.json; then
        echo "The image's web vault is $(cat /opt/vaultwarden/web-vault/version.json), not ${WEB_VAULT_VERSION}"

        exit 1
    fi

    fetch "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip" sqlite.zip ${SQLITE_SHA256}
    fetch "https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/${ARGON2_VERSION}.tar.gz" argon2.tar.gz \
        ${ARGON2_SHA256}

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        build_sqlite ${arch}
        build_argon2 ${arch}
        build_runas ${arch}

        # (the ARM build's program sits in its own folder in the image)
        program=/opt/vaultwarden/vaultwarden
        [ "${arch}" = armhf ] && program=/opt/vaultwarden/armhf/vaultwarden

        # Put together in a work folder first: the output only once it's checked (build_static.sh takes an output
        # folder that isn't empty as built)
        output=${BUILD_PATH}/${arch}/out
        mkdir -p ${output}
        cp ${program} ${output}/vaultwarden
        strip_for ${arch} ${output}/vaultwarden
        # The web vault, without its source maps (only used for debugging in a browser - over half its size)
        cp -r /opt/vaultwarden/web-vault ${output}/
        find ${output}/web-vault -name '*.map' -delete
        cp ${BUILD_PATH}/${arch}/sqlite3 ${BUILD_PATH}/${arch}/argon2 ${BUILD_PATH}/${arch}/vw_runas ${output}/
        # Certificate authorities, for Vaultwarden's own outgoing connections (e.g. icons, email, push notifications)
        cp /etc/ssl/certs/ca-certificates.crt ${output}/
        check ${arch} ${output}

        rm -rf /data/packages/static/vaultwarden/${VERSION}/${arch}
        mkdir -p /data/packages/static/vaultwarden/${VERSION}
        cp -r ${output} /data/packages/static/vaultwarden/${VERSION}/${arch}
        du -sh /data/packages/static/vaultwarden/${VERSION}/${arch}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/vaultwarden/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
