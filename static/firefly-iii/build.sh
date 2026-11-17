#!/bin/bash

# Prepares Firefly III for the NAS: its release (its source with its PHP packages - installed by its makers with
# Composer, without their development tools - and its built web interface), plus:
#  - firefly_runas (for each architecture): switches to Firefly III's own user (the NAS has no su or similar) before
#    running PHP
# Firefly III runs on the PHP app's PHP 8.5 (it needs PHP 8.5 or later), so no PHP is included.

# The ARM models' helper is cross-compiled on this (Intel) machine with Zig for their ARMv7 processors (hard-float), and
# checked for their kernels' large memory pages (ci/check_arm_pages.py) and run with QEMU's emulator. The PHP code is
# the same for both.

set -e
set -o pipefail
set -x

VERSION=6.7.9
FIREFLY_SHA256=f905729c3be6e66d5333c22992281224ef1dc7e21cea13f4ef09af643d09b825

# The architectures built (each into packages/static/firefly-iii/<version>/<arch>)
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

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

function build_firefly() {
    fetch "https://github.com/firefly-iii/firefly-iii/releases/download/v${VERSION}/FireflyIII-v${VERSION}.tar.gz" firefly.tar.gz ${FIREFLY_SHA256}
    mkdir firefly
    tar -xzf firefly.tar.gz -C firefly
    cd firefly
    grep -q "'version' *=> *'${VERSION}'" config/firefly.php
    # Its PHP packages, without their development tools
    [ -f vendor/autoload.php ] && [ ! -d vendor/phpunit ]
    # Laravel's router for PHP's own web server (which the app runs it with)
    [ -f vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php ]
    # Only needed to develop, test or build it
    rm -rf tests .env.example .env.testing phpunit.xml package.json package-lock.json eslint.config.mjs mago.toml \
        crowdin.yml agents.md .editorconfig .prettierignore .prettierrc .gitattributes .gitignore nginx_app.conf
    # Logs and caches made while its release was prepared: written again where the app keeps them
    rm -rf storage/logs/*.log storage/framework/cache/data/* storage/framework/views/*
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > firefly_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: firefly_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("firefly_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("firefly_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o firefly_runas firefly_runas.c
}

# Checks an architecture's helper in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local usage

    if ! file firefly_runas | grep -E 'statically linked|static-pie linked' > /dev/null; then
        echo "firefly_runas (${arch}) isn't static: $(file firefly_runas)"

        exit 1
    fi

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py firefly_runas
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./firefly_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: firefly_runas' > /dev/null
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_firefly
    du -sh ${BUILD_PATH}/firefly ${BUILD_PATH}/firefly/vendor

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/firefly-iii/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp firefly_runas ${output}/
        cp -r ${BUILD_PATH}/firefly ${output}/
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/firefly-iii/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
