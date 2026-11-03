#!/bin/bash

# Prepares Audiobookshelf for the NAS: its server (compiled from its source release) and web interface (built from it),
# with its packages installed, and its own Node.js runtime (its SQLite module is compiled for one Node version, so it
# doesn't share the Node.js app's), plus:
#  - ffmpeg / ffprobe: fully static (built in the Dockerfile): reading audio files, streaming them to its players (AAC),
#                      merging audiobooks into M4B, covers, and downloading podcast episodes (HTTPS)
#  - libnusqlite3:     SQLite's Unicode extension (nunicode), which its search and sorting use - as in its Docker image
#  - abs_runas:        switches to Audiobookshelf's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=2.37.2
ABS_SHA256=f729b7513aa0cfedbeaa44583e0e7d7ec60e3ccac87704afca6326e3da70421a
NODE_VERSION=24.22.2
NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
# The version Audiobookshelf expects, glibc build
NUNICODE_VERSION=1.2
NUNICODE_SHA256=6f82c7561224ee971f39bb341d0d2daf0b182ced496e254c5d14a3189dbcf7d5
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
OUTPUT_PATH=/data/packages/static/audiobookshelf/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Whether version $1 is newer than version $2
function newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Every compiled module and library must run with the NAS's own libraries (modules for other systems or processors are
# removed)
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
    done < <(find "$@" \( -name '*.node' -o -name '*.so' \))
}

function build_node() {
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    export PATH="${BUILD_PATH}/node/bin:${PATH}"
}

function build_audiobookshelf() {
    fetch "https://github.com/advplyr/audiobookshelf/archive/refs/tags/v${VERSION}.tar.gz" abs.tar.gz ${ABS_SHA256}
    tar -xzf abs.tar.gz
    local source=${BUILD_PATH}/audiobookshelf-${VERSION}

    # Its web interface (as its Docker image builds it)
    cd ${source}/client
    npm ci --no-audit --no-fund
    npm run generate

    # Its server: compiled (TypeScript) with its development packages, then installed with only what it runs with - on
    # the NAS's Debian version, so that SQLite's module suits the NAS's libraries
    cd ${source}
    npm ci --include=dev --ignore-scripts --no-audit --no-fund
    npm run build:server
    mkdir -p ${BUILD_PATH}/app/client
    cp -r dist-server index.js package.json package-lock.json ${BUILD_PATH}/app/
    cp -r server ${BUILD_PATH}/app/server
    cp -r client/dist ${BUILD_PATH}/app/client/dist
    cd ${BUILD_PATH}/app
    NODE_ENV=production npm ci --omit=dev --no-audit --no-fund
    check_modules node_modules

    fetch "https://github.com/mikiher/nunicode-sqlite/releases/download/v${NUNICODE_VERSION}/libnusqlite3-linux-x64.zip" \
        nunicode.zip ${NUNICODE_SHA256}
    unzip -o -q nunicode.zip -d ${BUILD_PATH}/nunicode
    check_modules ${BUILD_PATH}/nunicode
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > abs_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program. Files it creates are
// writable by the group too (umask 002), as the NAS's shares expect (e.g. downloaded podcast episodes)
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: abs_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("abs_runas: could not switch user");
		return 1;
	}
	umask(002);
	execv(argv[3], &argv[3]);
	perror("abs_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o abs_runas abs_runas.c
    strip abs_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_node
    build_audiobookshelf
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    # Node's own npm, headers and documentation aren't needed to run it
    mkdir -p ${OUTPUT_PATH}/node/bin
    cp ${BUILD_PATH}/node/bin/node ${OUTPUT_PATH}/node/bin/
    cp ${BUILD_PATH}/node/LICENSE ${OUTPUT_PATH}/node/
    cp -a ${BUILD_PATH}/app ${OUTPUT_PATH}/app
    cp ${BUILD_PATH}/nunicode/libnusqlite3.so ${BUILD_PATH}/abs_runas /opt/ffmpeg /opt/ffprobe ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/node/bin/node -e "require('${OUTPUT_PATH}/app/node_modules/sqlite3'); console.log('SQLite module loads')"
    ${OUTPUT_PATH}/ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt && head -n 1 ${BUILD_PATH}/ffmpeg-version.txt
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/* ${OUTPUT_PATH}/app/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
