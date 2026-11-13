#!/bin/bash

# Prepares BookStack for the NAS: its release (its source with its built web interface) with its PHP packages installed
# by Composer (exactly the versions in its composer.lock, without its development tools), plus:
#  - bookstack_runas (for each architecture): switches to BookStack's own user (the NAS has no su or similar) before
#    running PHP
# BookStack runs on the PHP app's PHP 8.5 (it needs PHP 8.2 or later), so no PHP is included.

# The ARM models' helper is cross-compiled on this (Intel) machine with Zig for their ARMv7 processors (hard-float), and
# checked for their kernels' large memory pages (ci/check_arm_pages.py) and run with QEMU's emulator. The PHP code is
# the same for both.

set -e
set -o pipefail
set -x

VERSION=26.09.3
BOOKSTACK_SHA256=d2547a63aee9bca10281eeffcb4965cb3a85f20217d62430c538ec6ad4817a75
COMPOSER_VERSION=2.11.1
COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c

# The architectures built (each into packages/static/bookstack/<version>/<arch>)
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

function build_bookstack() {
    fetch "https://github.com/BookStackApp/BookStack/archive/refs/tags/v${VERSION}.tar.gz" bookstack.tar.gz ${BOOKSTACK_SHA256}
    fetch "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" composer.phar ${COMPOSER_SHA256}
    tar -xzf bookstack.tar.gz
    mv BookStack-${VERSION} bookstack
    cd bookstack
    grep -q "^v${VERSION}$" version
    # The image's PHP lacks some of the extensions BookStack uses (gd, zip...): the PHP app's has them all, and they
    # only matter when it runs
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_HOME=${BUILD_PATH}/composer php ${BUILD_PATH}/composer.phar install --no-dev \
        --no-interaction --no-progress --optimize-autoloader --ignore-platform-req='ext-*'
    # Laravel's router for PHP's own web server (which the app runs it with)
    [ -f vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php ]
    # Only needed to develop, test or build it (dev/licensing stays: its licences page reads it)
    rm -rf .github .forgejo tests dev/build dev/docker dev/docs node_modules storage/logs/* .env.example.complete
    rm -f docker-compose.yml phpunit.xml phpcs.xml phpstan.neon.dist eslint.config.mjs jest.config.ts tsconfig.json \
        package.json package-lock.json crowdin.yml
    # Laravel's caches made while installing: written again where the app keeps them
    rm -rf storage/framework/cache/data/* storage/framework/views/*
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > bookstack_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: bookstack_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("bookstack_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("bookstack_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o bookstack_runas bookstack_runas.c
}

# Checks an architecture's helper in the current folder: static, (ARM) laid out for large memory pages, and running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local usage

    if ! file bookstack_runas | grep -E 'statically linked|static-pie linked' > /dev/null; then
        echo "bookstack_runas (${arch}) isn't static: $(file bookstack_runas)"

        exit 1
    fi

    [ "${arch}" = armhf ] && python3 /data/ci/check_arm_pages.py bookstack_runas
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./bookstack_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: bookstack_runas' > /dev/null
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_bookstack
    du -sh ${BUILD_PATH}/bookstack ${BUILD_PATH}/bookstack/vendor

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/bookstack/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp bookstack_runas ${output}/
        cp -r ${BUILD_PATH}/bookstack ${output}/
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/bookstack/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
