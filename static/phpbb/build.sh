#!/bin/bash

# Prepares phpBB for the NAS as phpBB's own release packages are made (its build/build.xml): the phpBB folder of its
# release tag, with its PHP packages installed by Composer (exactly those in its composer.lock, without its development
# tools), plus:
#  - phpbb_runas: switches to phpBB's own user (the NAS has no su or similar) before running PHP
# phpBB runs on the PHP app's PHP 8.5, so no PHP is included. phpBB's own downloads (download.phpbb.com) sit behind a
# browser check that builds can't pass, so the tag's source archive is used, pinned by its SHA256. Not included: the
# VigLink extension its packages add (it turns links in posts into affiliate links).

set -e
set -o pipefail
set -x

VERSION=3.3.19
PHPBB_SHA256=4e630c46ecf19c777816d02b226289c6b3b1d6cb134400f604fa504d868c0c86
COMPOSER_VERSION=2.11.1
COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/phpbb/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

function build_phpbb() {
    fetch "https://github.com/phpbb/phpbb/archive/refs/tags/release-${VERSION}.tar.gz" phpbb.tar.gz ${PHPBB_SHA256}
    fetch "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" composer.phar ${COMPOSER_SHA256}
    tar -xzf phpbb.tar.gz
    mv phpbb-release-${VERSION}/phpBB phpbb
    cd phpbb
    grep -q "'PHPBB_VERSION', '${VERSION}'" includes/constants.php
    # As phpBB's release packages are made (the image's PHP lacks some of the extensions phpBB uses: the PHP app's has
    # them, and they only matter when it runs)
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_HOME=${BUILD_PATH}/composer php ${BUILD_PATH}/composer.phar install --no-dev \
        --no-interaction --no-progress --optimize-autoloader --ignore-platform-reqs
    # Only needed to develop it; the empty config.php its packages have is made by the app
    rm -rf develop composer.phar web.config
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > phpbb_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: phpbb_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("phpbb_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("phpbb_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o phpbb_runas phpbb_runas.c
    strip phpbb_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_phpbb
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/phpbb_runas ${OUTPUT_PATH}/
    cp -r ${BUILD_PATH}/phpbb ${OUTPUT_PATH}/
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/phpbb/vendor

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
