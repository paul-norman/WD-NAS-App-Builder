#!/bin/bash

# Prepares Uptime Kuma for the NAS: its release (source + prebuilt web interface) with its packages installed, and its
# own Node.js runtime (its SQLite module is compiled for one Node version, so it doesn't share the Node.js app's), plus
# fully static builds of the tools the app uses alongside it:
#  - sqlite3:    SQLite's shell, for safe backups of the database while Uptime Kuma runs
#  - kuma_runas: switches to Uptime Kuma's own user (the NAS has no su or similar) before running it
#  - ping:       iputils' ping (built in the Dockerfile), which pings without root - BusyBox's needs it

set -e
set -o pipefail
set -x

VERSION=2.5.9
UPTIME_KUMA_SHA256=ec8f96ca282f958c26b99a8001d7cb469b4ab7b00765458d062920aae6010527
UPTIME_KUMA_DIST_SHA256=f979084bbc74dc80a142d91d09b807f0a4ed52c06830c0e44c36adc9e77c064b
NODE_VERSION=24.22.2
NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
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
OUTPUT_PATH=/data/packages/static/uptime-kuma/${VERSION}/${ARCH}

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
# packages include, e.g. oracledb's for macOS, Windows and ARM, are removed)
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

function build_uptime_kuma() {
    fetch "https://github.com/louislam/uptime-kuma/archive/refs/tags/${VERSION}.tar.gz" uptime-kuma.tar.gz ${UPTIME_KUMA_SHA256}
    fetch "https://github.com/louislam/uptime-kuma/releases/download/${VERSION}/dist.tar.gz" dist.tar.gz ${UPTIME_KUMA_DIST_SHA256}
    tar -xzf uptime-kuma.tar.gz
    mv uptime-kuma-${VERSION} uptime-kuma
    tar -xzf dist.tar.gz -C uptime-kuma
    cd uptime-kuma
    # As its own Docker image does (no browser download: the "real browser" monitor isn't offered natively)
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 npm ci --omit=dev --no-audit --no-fund
    # Only needed to develop, test or build it (or for its Docker images)
    rm -rf .github .devcontainer docker test config/playwright.config.js node_modules/.cache
    check_modules node_modules
}

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
    gcc -O2 -static -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -lm -o sqlite3
    strip sqlite3
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > kuma_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: kuma_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("kuma_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("kuma_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o kuma_runas kuma_runas.c
    strip kuma_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_node
    build_uptime_kuma
    build_sqlite
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/node/bin/node ${OUTPUT_PATH}/
    cp -r ${BUILD_PATH}/uptime-kuma ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/sqlite-amalgamation-${SQLITE_VERSION}/sqlite3 ${BUILD_PATH}/kuma_runas /opt/ping ${OUTPUT_PATH}/

    if ldd ${OUTPUT_PATH}/ping 2>&1 | grep -q '=>'; then
        echo "ping isn't static"

        exit 1
    fi
    ${OUTPUT_PATH}/node --version
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/uptime-kuma/node_modules

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
