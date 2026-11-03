#!/bin/bash

# Prepares Vaultwarden for the NAS: its official static program and web vault (copied out of its Alpine image by the
# Dockerfile), plus fully static builds of the tools the app uses alongside it:
#  - sqlite3: SQLite's shell, for safe backups of the database while Vaultwarden runs
#  - argon2:  the reference Argon2 tool, which hashes the admin token the way Vaultwarden's documentation does
#  - vw_runas: switches to Vaultwarden's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

# Must match the image tag in amd64.Dockerfile
VERSION=1.37.5
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
ARGON2_VERSION=20190702
ARGON2_SHA256=daf972a89577f8772602bf2eb38b6a3dd3d922bf5724d45e7f9589b5e830442c

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/vaultwarden/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    wget -q "$1" -O "$2"
    echo "$3  $2" | sha256sum -c -
}

function check_static() {
    if ldd "$1" 2>&1 | grep -q '=>'; then
        echo "$1 isn't static"

        exit 1
    fi
}

function build_sqlite() {
    fetch "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip" sqlite.zip ${SQLITE_SHA256}
    unzip -q sqlite.zip
    cd sqlite-amalgamation-${SQLITE_VERSION}
    gcc -O2 -static -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o sqlite3
    strip sqlite3
    check_static sqlite3
}

function build_argon2() {
    fetch "https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/${ARGON2_VERSION}.tar.gz" argon2.tar.gz ${ARGON2_SHA256}
    tar -xzf argon2.tar.gz
    cd phc-winner-argon2-${ARGON2_VERSION}
    # A generic target: the default (native) would tune it to the build machine's processor
    make argon2 OPTTARGET=x86-64 LDFLAGS='-static -pthread'
    strip argon2
    check_static argon2
}

function build_runas() {
    cd ${BUILD_PATH}
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
    gcc -O2 -static -o vw_runas vw_runas.c
    strip vw_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    # The image's program must be the version being packaged, and static
    /opt/vaultwarden/vaultwarden --version | grep -q "^Vaultwarden ${VERSION}$" || { echo "The image holds $(/opt/vaultwarden/vaultwarden --version), not ${VERSION}"; exit 1; }
    check_static /opt/vaultwarden/vaultwarden

    build_sqlite
    build_argon2
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp /opt/vaultwarden/vaultwarden ${OUTPUT_PATH}/
    strip ${OUTPUT_PATH}/vaultwarden
    # The web vault, without its source maps (only used for debugging in a browser - over half its size)
    cp -r /opt/vaultwarden/web-vault ${OUTPUT_PATH}/
    find ${OUTPUT_PATH}/web-vault -name '*.map' -delete
    cp ${BUILD_PATH}/sqlite-amalgamation-${SQLITE_VERSION}/sqlite3 ${BUILD_PATH}/phc-winner-argon2-${ARGON2_VERSION}/argon2 ${BUILD_PATH}/vw_runas ${OUTPUT_PATH}/
    # Certificate authorities, for Vaultwarden's own outgoing connections (e.g. icons, email, push notifications)
    cp /etc/ssl/certs/ca-certificates.crt ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/vaultwarden --version
    ${OUTPUT_PATH}/sqlite3 --version
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
