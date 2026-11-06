#!/bin/bash

# Prepares Compass Web for the NAS: the compass-web package (an unofficial port of MongoDB Compass to the browser - its
# server, and Compass's web interface it serves) with its packages, from static/compass-web/package.json - each
# version with its checksum in package-lock.json, written by the first build, then reused (so that rebuilds install
# exactly the same packages; delete it to take newer ones) - and its own Node.js runtime (its compiled parts are built
# for one Node version, so it doesn't share the Node.js app's). package.json holds @fastify/secure-session at 8.2.0
# (within compass-web's range): newer ones use sodium-native 5, whose ready-built module needs a newer glibc than the
# NAS's and which can't be built on its Debian version. Plus:
#  - cw_runas: switches to Compass Web's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=0.5.2
NODE_VERSION=24.22.2
NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
# The newest glibc / libstdc++ symbol versions the NAS has (OS5: glibc 2.31, GLIBCXX 3.4.28)
NAS_GLIBC=2.31
NAS_GLIBCXX=3.4.28

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/compass-web/${VERSION}/${ARCH}
LOCK=/data/static/compass-web/package-lock.json

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Whether version $1 is newer than version $2
function newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Every compiled module must run with the NAS's own libraries (modules for other systems or processors, which some
# packages include, are removed)
function check_modules() {
    local module glibc glibcxx

    while read -r module; do
        if [ "$(head -c 4 "${module}" | tail -c 3)" != ELF ] || ! objdump -f "${module}" | grep -q 'x86-64'; then
            rm -f "${module}"
            continue
        fi

        # A module may use no C++ at all: grep finding nothing isn't an error
        glibc="$(objdump -T "${module}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -V | tail -n 1)"
        glibcxx="$(objdump -T "${module}" | { grep -o 'GLIBCXX_[0-9.]*' || true; } | sed 's/GLIBCXX_//' | sort -V | tail -n 1)"
        echo "${module}: GLIBC ${glibc:-none}, GLIBCXX ${glibcxx:-none}"

        if { [ -n "${glibc}" ] && newer "${glibc}" "${NAS_GLIBC}"; } || { [ -n "${glibcxx}" ] && newer "${glibcxx}" "${NAS_GLIBCXX}"; }; then
            echo "${module} needs newer libraries than the NAS has"

            exit 1
        fi
    done < <(find "$1" -name '*.node')
}

function build_node() {
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    export PATH="${BUILD_PATH}/node/bin:${PATH}"
}

function build_compass_web() {
    mkdir -p ${BUILD_PATH}/compass-web
    cd ${BUILD_PATH}/compass-web
    cp /data/static/compass-web/package.json .

    # The locked packages if there are some (their checksums checked by npm), else the newest matching ones - locked
    if [ -f "${LOCK}" ]; then
        cp "${LOCK}" .
        npm ci --omit=dev --no-audit --no-fund
    else
        npm install --omit=dev --no-audit --no-fund
        cp package-lock.json "${LOCK}"
    fi

    grep -q "\"version\": \"${VERSION}\"" node_modules/compass-web/package.json
    rm -rf node_modules/.cache
    check_modules node_modules
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > cw_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: cw_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("cw_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("cw_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o cw_runas cw_runas.c
    strip cw_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_node
    build_compass_web
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/node/bin/node ${BUILD_PATH}/cw_runas ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/node/LICENSE ${OUTPUT_PATH}/node-LICENSE
    cp -r ${BUILD_PATH}/compass-web ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/node --version
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/compass-web/node_modules

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/compass-web/package-lock.json
}

run
