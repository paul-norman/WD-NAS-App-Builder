#!/bin/bash

# Prepares Vikunja for the NAS - for the Intel models and the ARM ones: its official static program for each (its web
# app is inside it), plus fully static builds of:
#  - sqlite3: SQLite's shell, for safe backups of Vikunja's database while it runs, and for the page's list of users
#  - vikunja_runas: switches to Vikunja's own user (the NAS has no su or similar) before running it. With --pty it runs
#    the program in a pseudo-terminal fed from its input: Vikunja only reads new passwords from a terminal, and this
#    keeps them off the command line
# The ARM models' parts are built on this (Intel) machine: the helpers cross-compiled with Zig for their ARMv7
# processors (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=2.8.0
# Each architecture's release (a zip, hashed here: the release publishes only its program's SHA256, inside the zip -
# checked too)
VIKUNJA_SHA256=0b6ba2934bd432eefaa4209b0f96d20b7f7cd7f7be0269dd79071979c4363423
VIKUNJA_ARMHF_SHA256=06ac3f7892cdb05b1d0c220fff4d2c5556208ed808db44f2eded4a41180ade57
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
# The architectures built (each into packages/static/vikunja/<version>/<arch>)
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

# Downloads a file, checking its SHA256 (static/fetch.sh: a kept copy, its site, then the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Downloads Vikunja's release for an architecture into the current folder, checking its program against the SHA256 in
# the zip too.
#
# $1 arch The architecture (amd64 or armhf)
function build_vikunja() {
    local name

    if [ "$1" = armhf ]; then
        name="vikunja-v${VERSION}-linux-arm-7"
        fetch "https://github.com/go-vikunja/vikunja/releases/download/v${VERSION}/${name}-full.zip" vikunja.zip \
            "${VIKUNJA_ARMHF_SHA256}"
    else
        name="vikunja-v${VERSION}-linux-amd64"
        fetch "https://github.com/go-vikunja/vikunja/releases/download/v${VERSION}/${name}-full.zip" vikunja.zip \
            "${VIKUNJA_SHA256}"
    fi

    mkdir -p release
    unzip -q vikunja.zip -d release
    (cd release && sha256sum -c "${name}.sha256")
    mv "release/${name}" vikunja
}

# Builds SQLite's shell for an architecture in the current folder (as static/grafana does).
#
# $1 arch The architecture (amd64 or armhf)
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
    cc_for "$1" -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o ../sqlite3
    cd ..
}

# Builds the run-as helper for an architecture in the current folder (with --pty, as static/navidrome's).
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > vikunja_runas.c <<'C'
#include <errno.h>
#include <grp.h>
#include <pty.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program. With --pty, the
// program runs in a pseudo-terminal: everything on this program's input is typed into it, and its output is passed on
static void switch_user(const char *uid_text, const char *gid_text) {
	uid_t uid = (uid_t)strtoul(uid_text, NULL, 10);
	gid_t gid = (gid_t)strtoul(gid_text, NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("vikunja_runas: could not switch user");
		exit(1);
	}
}

int main(int argc, char **argv) {
	int pty = argc > 1 && strcmp(argv[1], "--pty") == 0;
	if (pty) {
		argv++;
		argc--;
	}
	if (argc < 4) {
		fprintf(stderr, "Usage: vikunja_runas [--pty] <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	if (!pty) {
		switch_user(argv[1], argv[2]);
		execv(argv[3], &argv[3]);
		perror("vikunja_runas: could not run the program");
		return 127;
	}

	// What's to be typed (e.g. a password, twice), read before starting the program
	char input[4096];
	size_t length = fread(input, 1, sizeof(input), stdin);
	int master;
	pid_t pid = forkpty(&master, NULL, NULL, NULL);
	if (pid < 0) {
		perror("vikunja_runas: could not open a pseudo-terminal");
		return 1;
	}
	if (pid == 0) {
		switch_user(argv[1], argv[2]);
		execv(argv[3], &argv[3]);
		perror("vikunja_runas: could not run the program");
		_exit(127);
	}
	if (length > 0 && write(master, input, length) < 0) {
		perror("vikunja_runas: could not type into the program");
	}
	memset(input, 0, sizeof(input));
	char buffer[4096];
	ssize_t got;
	while ((got = read(master, buffer, sizeof(buffer))) > 0 || (got < 0 && errno == EINTR)) {
		if (got > 0) {
			fwrite(buffer, 1, (size_t)got, stdout);
		}
	}
	int status;
	if (waitpid(pid, &status, 0) < 0) {
		return 1;
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
    cc_for "$1" -o vikunja_runas vikunja_runas.c
}

function run() {
    local arch output usage

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_vikunja ${arch}
        build_sqlite ${arch}
        build_runas ${arch}

        output=/data/packages/static/vikunja/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp vikunja sqlite3 vikunja_runas ${output}/
        run_for ${arch} ${output}/vikunja version | grep -q "v${VERSION}"
        [ "$(echo 'SELECT 1;' | run_for ${arch} ${output}/sqlite3 :memory:)" = 1 ]
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/vikunja_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: vikunja_runas'
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/vikunja/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
