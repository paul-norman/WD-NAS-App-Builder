#!/bin/bash

# Prepares BookStack for the NAS: its release (its source with its built web interface) with its PHP packages installed
# by Composer (exactly the versions in its composer.lock, without its development tools), plus:
#  - bookstack_runas: switches to BookStack's own user (the NAS has no su or similar) before running PHP
# BookStack runs on the PHP app's PHP 8.5 (it needs PHP 8.2 or later), so no PHP is included.

set -e
set -o pipefail
set -x

VERSION=26.09.2
BOOKSTACK_SHA256=63d6be10b6d2db89a5f82c439e478480fc12daaaca0de9a88a700b583e1d2c65
COMPOSER_VERSION=2.11.1
COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/bookstack/${VERSION}/${ARCH}

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

function build_runas() {
    cd ${BUILD_PATH}
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
    gcc -O2 -static -o bookstack_runas bookstack_runas.c
    strip bookstack_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_bookstack
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/bookstack_runas ${OUTPUT_PATH}/
    cp -r ${BUILD_PATH}/bookstack ${OUTPUT_PATH}/
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/bookstack/vendor

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
