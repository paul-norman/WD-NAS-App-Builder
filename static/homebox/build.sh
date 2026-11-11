#!/bin/bash

# Prepares Homebox for the NAS (the Intel models - Homebox publishes no 32-bit ARM release): its official program, plus
# fully static builds of:
#  - sqlite3: SQLite's shell, for safe backups of Homebox's database while it runs
#  - homebox_runas: switches to Homebox's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=0.27.1
# As its checksums.txt publishes it
HOMEBOX_SHA256=8fc79c96a1317c58b652165e7cc221787c7b89eb03cb57b5e3a4139e6e17a2c0
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

BUILD_PATH=/build

# Downloads a file, checking its SHA256 (static/fetch.sh: a kept copy, its site, then the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Builds SQLite's shell in the current folder (as static/grafana does).
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
    gcc -O2 -static -s -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o ../sqlite3
    cd ..
}

# Builds the run-as helper in the current folder.
function build_runas() {
    cat > homebox_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: homebox_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("homebox_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("homebox_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o homebox_runas homebox_runas.c
}

# Downloads Homebox's release into the current folder.
function build_homebox() {
    fetch "https://github.com/sysadminsmedia/homebox/releases/download/v${VERSION}/homebox_Linux_x86_64.tar.gz" \
        homebox.tar.gz "${HOMEBOX_SHA256}"
    mkdir -p release
    tar -xzf homebox.tar.gz -C release
    mv release/homebox homebox
}

function run() {
    local output usage

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}
    build_homebox
    build_sqlite
    build_runas

    output=/data/packages/static/homebox/${VERSION}/amd64
    rm -rf ${output}
    mkdir -p ${output}
    cp homebox sqlite3 homebox_runas ${output}/
    # (A glibc program - this machine's musl can't run it: its version is checked in its own text)
    grep -aq "${VERSION}" ${output}/homebox
    [ "$(echo 'SELECT 1;' | ${output}/sqlite3 :memory:)" = 1 ]
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(${output}/homebox_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: homebox_runas'
    du -sh ${output}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/homebox/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
