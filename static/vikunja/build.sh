#!/bin/bash

# Prepares Vikunja for the NAS - for the Intel models and the ARM ones (its web app is inside it), plus fully static
# builds of:
#  - sqlite3: SQLite's shell, for safe backups of Vikunja's database while it runs, and for the page's list of users
#  - vikunja_runas: switches to Vikunja's own user (the NAS has no su or similar) before running it. With --pty it runs
#    the program in a pseudo-terminal fed from its input: Vikunja only reads new passwords from a terminal, and this
#    keeps them off the command line
#
# Intel: Vikunja's official static program. ARM: built here from Vikunja's source, as its official ARM program is laid
# out for 4KB memory pages and the ARM models' kernels use larger ones (32KB on the EX2 Ultra: it crashes there) - its
# web app first (pnpm, from its lock file), then Vikunja for ARMv7 with Go, its C parts (SQLite) cross-compiled and the
# whole linked statically by Zig, which lays programs out for 64KB pages. The helpers are cross-compiled with Zig too.
# Every ARM program is checked for that layout (ci/check_arm_pages.py) and run with QEMU's emulator: Vikunja makes its
# database and serves its API and web app.

set -e
set -o pipefail
set -x

VERSION=2.8.0
# Each architecture's release (a zip, hashed here: the release publishes only its program's SHA256, inside the zip -
# checked too)
VIKUNJA_SHA256=0b6ba2934bd432eefaa4209b0f96d20b7f7cd7f7be0269dd79071979c4363423
# Its source (GitHub's archive of the release's tag), for the ARM build, and the pnpm its web app is built with
VIKUNJA_SOURCE_SHA256=c7bfb1c4d4f577b3cbad62e2e77abb85802709fdeff7f1d366b90badc5fc7f94
PNPM_VERSION=12.16.1
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
        build_arm_vikunja

        return 0
    fi

    name="vikunja-v${VERSION}-linux-amd64"
    fetch "https://github.com/go-vikunja/vikunja/releases/download/v${VERSION}/${name}-full.zip" vikunja.zip \
        "${VIKUNJA_SHA256}"

    mkdir -p release
    unzip -q vikunja.zip -d release
    (cd release && sha256sum -c "${name}.sha256")
    mv "release/${name}" vikunja
}

# Builds Vikunja for the ARM models from its source, into the current folder: its web app (embedded in it), then
# Vikunja with Go for ARMv7 - SQLite cross-compiled and everything linked statically by Zig (64KB pages).
function build_arm_vikunja() {
    local here="$(pwd)"
    local source="${here}/vikunja-${VERSION}"

    fetch "https://github.com/go-vikunja/vikunja/archive/refs/tags/v${VERSION}.tar.gz" source.tar.gz \
        "${VIKUNJA_SOURCE_SHA256}"
    tar -xzf source.tar.gz

    cd "${source}/frontend"
    npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}"
    pnpm install --frozen-lockfile
    pnpm run build

    cd "${source}"
    CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7 CC='zig cc -target arm-linux-musleabihf -mcpu=cortex_a9' \
        go build -o "${here}/vikunja" -tags 'osusergo netgo sqlite_omit_load_extension' \
        -ldflags "-linkmode=external -extldflags=-static -s -w -X code.vikunja.io/api/pkg/version.Version=v${VERSION}"
    cd "${here}"
}

# Checks the ARM build of Vikunja (in the current folder) with QEMU's emulator: it makes its SQLite database and serves
# its API and its web app.
function check_arm_serving() {
    local url=http://127.0.0.1:13456
    local pid i

    rm -rf /tmp/vikunja-test
    mkdir -p /tmp/vikunja-test
    VIKUNJA_DATABASE_TYPE=sqlite VIKUNJA_DATABASE_PATH=/tmp/vikunja-test/vikunja.db \
        VIKUNJA_SERVICE_INTERFACE=127.0.0.1:13456 VIKUNJA_SERVICE_PUBLICURL=${url}/ \
        VIKUNJA_FILES_BASEPATH=/tmp/vikunja-test/files qemu-arm -cpu cortex-a9 ./vikunja web \
        > /tmp/vikunja-test/web.log 2>&1 &
    pid=$!

    for i in $(seq 1 120); do
        curl -sf -o /dev/null ${url}/api/v1/info && break
        sleep 1
    done

    curl -sf ${url}/api/v1/info | grep "v${VERSION}" > /dev/null
    curl -sf ${url}/ | grep -i '<html' > /dev/null
    [ -s /tmp/vikunja-test/vikunja.db ]
    kill ${pid}
    wait ${pid} 2> /dev/null || true
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
    local arch output usage version

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

        if [ "${arch}" = armhf ]; then
            python3 /data/ci/check_arm_pages.py vikunja sqlite3 vikunja_runas
            check_arm_serving
        fi

        # (its output captured first: grep -q stops reading at a match, and Vikunja - still writing - would fail on the
        # closed pipe, failing the build under set -o pipefail)
        version="$(run_for ${arch} ./vikunja version)"
        echo "${version}" | grep "v${VERSION}" > /dev/null
        [ "$(echo 'SELECT 1;' | run_for ${arch} ./sqlite3 :memory:)" = 1 ]
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ./vikunja_runas 2>&1 || true)"
        echo "${usage}" | grep 'Usage: vikunja_runas' > /dev/null

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/vikunja/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp vikunja sqlite3 vikunja_runas ${output}/
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
