#!/bin/bash

# Prepares Wiki.js for the NAS: its release (its server, with its packages installed, and its prebuilt web interface)
# and its own Node.js runtime (Wiki.js 3 needs Node.js 26 - it runs its TypeScript directly), plus:
#  - wikijs_runas: switches to Wiki.js's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=3.1.1
WIKIJS_SHA256=dc9200f078ba959dadb7b59417a902f8c7c6fdc7991119c69d15716db4e8cfcc
NODE_VERSION=26.13.0
NODE_SHA256=d28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997
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
OUTPUT_PATH=/data/packages/static/wikijs/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Whether version $1 is newer than version $2
function newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Every compiled part (Node.js modules and the libraries they load, e.g. Sharp's libvips) must run with the NAS's own
# libraries; parts for other systems or processors are removed
function check_compiled() {
    local file glibc glibcxx

    while read -r file; do
        if [ "$(head -c 4 "${file}" | tail -c 3)" != ELF ] || ! objdump -f "${file}" | grep -q 'x86-64'; then
            rm -f "${file}"
            continue
        fi

        # A part may use no C++ at all: grep finding nothing isn't an error
        glibc="$(objdump -T "${file}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -V | tail -n 1)"
        glibcxx="$(objdump -T "${file}" | { grep -o 'GLIBCXX_[0-9.]*' || true; } | sed 's/GLIBCXX_//' | sort -V | tail -n 1)"
        echo "${file}: GLIBC ${glibc:-none}, GLIBCXX ${glibcxx:-none}"

        if { [ -n "${glibc}" ] && newer "${glibc}" "${NAS_GLIBC}"; } || { [ -n "${glibcxx}" ] && newer "${glibcxx}" "${NAS_GLIBCXX}"; }; then
            echo "${file} needs newer libraries than the NAS has"

            exit 1
        fi
    done < <(find "$1" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \))
}

function build_node() {
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    check_compiled node/bin
}

function build_wikijs() {
    fetch "https://github.com/requarks/wiki/releases/download/${VERSION}/wiki-js.tar.gz" wiki-js.tar.gz ${WIKIJS_SHA256}
    mkdir wiki
    tar -xzf wiki-js.tar.gz -C wiki
    # The version Wiki.js reports is its package's
    grep -q "\"version\": \"${VERSION}\"" wiki/backend/package.json
    check_compiled wiki/backend/node_modules
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > wikijs_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: wikijs_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("wikijs_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("wikijs_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o wikijs_runas wikijs_runas.c
    strip wikijs_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_node
    build_wikijs
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    # Only Node.js itself: Wiki.js's packages come installed (no npm needed)
    cp ${BUILD_PATH}/node/bin/node ${BUILD_PATH}/wikijs_runas ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/node/LICENSE ${OUTPUT_PATH}/node-LICENSE
    cp -r ${BUILD_PATH}/wiki ${OUTPUT_PATH}/

    ${OUTPUT_PATH}/node --version
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/wiki/backend/node_modules

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
