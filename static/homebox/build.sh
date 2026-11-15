#!/bin/bash

# Prepares Homebox for the NAS - for the Intel models and the ARM ones - plus fully static builds, for each, of:
#  - sqlite3: SQLite's shell, for safe backups of Homebox's database while it runs
#  - homebox_runas: switches to Homebox's own user (the NAS has no su or similar) before running it
# Intel: Homebox's official program (its archive's SHA256, as its release's checksums.txt gives it, pinned here). ARM:
# Homebox has no release for 32-bit ARM, so it's built from the release's source (GitHub's archive of its tag, SHA256
# pinned here) as its own Dockerfile builds it for 32-bit ARM: its web app first (Nuxt, pnpm from its lock file), then
# Homebox with Go - no C parts, and with the nodynamic tag: its image formats (AVIF, HEIC, JPEG XL, WebP) from their
# WebAssembly builds, not the system's libraries (the NAS has none) - fully static.

# The ARM models' parts are made on this (Intel) machine: the C tools cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked for their kernels' large memory pages (ci/check_arm_pages.py) and run
# with QEMU's emulator - Homebox started, and asked its version.

set -e
set -o pipefail
set -x

VERSION=0.27.1
# As its checksums.txt publishes it
HOMEBOX_SHA256=8fc79c96a1317c58b652165e7cc221787c7b89eb03cb57b5e3a4139e6e17a2c0
HOMEBOX_SOURCE_SHA256=db2e13136dd046d644ee173924a4bfd596f6954598eb064acc4b3153b3993c17
# The pnpm its web app is built with (its package.json's packageManager)
PNPM_VERSION=10.28.0
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
# The architectures built (each into packages/static/homebox/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

# Downloads a file, checking its SHA256 (static/fetch.sh: a kept copy, its site, then the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

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

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
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
    cc_for "$1" -o homebox_runas homebox_runas.c
}

# Prepares Homebox for an architecture in the current folder, as ./homebox: the official release for amd64, built from
# its source for armhf.
#
# $1 arch The architecture (amd64 or armhf)
function build_homebox() {
    if [ "$1" = armhf ]; then
        build_homebox_source

        return
    fi

    fetch "https://github.com/sysadminsmedia/homebox/releases/download/v${VERSION}/homebox_Linux_x86_64.tar.gz" \
        homebox.tar.gz "${HOMEBOX_SHA256}"
    mkdir -p release
    tar -xzf homebox.tar.gz -C release
    mv release/homebox homebox
}

# Builds Homebox for ARMv7 from its source in the current folder, as ./homebox: its web app (embedded in the program),
# then Homebox itself - with its version set as its release's is.
function build_homebox_source() {
    local folder="${PWD}"

    fetch "https://github.com/sysadminsmedia/homebox/archive/refs/tags/v${VERSION}.tar.gz" homebox-source.tar.gz \
        "${HOMEBOX_SOURCE_SHA256}"
    mkdir -p source
    tar -xzf homebox-source.tar.gz -C source --strip-components=1

    cd source/frontend
    npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}"
    pnpm install --frozen-lockfile
    NUXT_TELEMETRY_DISABLED=1 pnpm run build

    cd ../backend
    rm -rf app/api/static/public
    cp -r ../frontend/.output/public app/api/static/public
    CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -tags nodynamic \
        -ldflags "-s -w -X main.version=${VERSION} -X main.commit=v${VERSION}" -o "${folder}/homebox" ./app/api
    cd "${folder}"
}

# Starts Homebox (built for an architecture) in a scratch folder on this machine only, and checks that it answers with
# its version and serves its web app; stops it again.
#
# $1 arch The architecture (amd64 or armhf)
function check_homebox() {
    local arch="$1"
    local data=${BUILD_PATH}/check-${arch}
    local pid status attempt

    mkdir -p ${data}
    # (started directly, not through run_for: stopping it must stop Homebox itself)
    if [ "${arch}" = armhf ]; then
        set -- qemu-arm -cpu cortex-a9 ./homebox
    else
        set -- ./homebox
    fi
    HBOX_MODE=production HBOX_WEB_HOST=127.0.0.1 HBOX_WEB_PORT=7745 HBOX_STORAGE_CONN_STRING="file://${data}" \
        HBOX_STORAGE_PREFIX_PATH=data HBOX_DATABASE_DRIVER=sqlite3 \
        HBOX_DATABASE_SQLITE_PATH="${data}/homebox.db?_pragma=busy_timeout=2000&_pragma=journal_mode=WAL&_fk=1" \
        HBOX_AUTH_API_KEY_PEPPER=0123456789abcdef0123456789abcdef HBOX_OPTIONS_ALLOW_ANALYTICS=false \
        HBOX_OPTIONS_GITHUB_RELEASE_CHECK=false TMPDIR=${data} "$@" > ${data}.log 2>&1 &
    pid=$!
    status=''

    for attempt in $(seq 1 90); do
        status="$(wget -qO- http://127.0.0.1:7745/api/v1/status 2>/dev/null || true)"
        [ -n "${status}" ] && break
        sleep 1
    done

    echo "${status}"

    if ! echo "${status}" | grep -q "\"version\":\"${VERSION}\"" \
        || ! wget -qO- http://127.0.0.1:7745/ | grep -qi '<html'; then
        cat ${data}.log
        kill ${pid}

        exit 1
    fi

    kill ${pid}
    wait ${pid} || true
}

# Checks an architecture's programs in the current folder: (ARM) static and laid out for large memory pages, and
# running.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local program usage

    if [ "${arch}" = armhf ]; then
        for program in homebox sqlite3 homebox_runas; do
            if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
                echo "${program} (${arch}) isn't static: $(file ${program})"

                exit 1
            fi
        done

        python3 /data/ci/check_arm_pages.py homebox sqlite3 homebox_runas
        check_homebox ${arch}
    else
        # (A glibc program - this machine's musl can't run it: its version is checked in its own text)
        grep -aq "${VERSION}" homebox
    fi

    [ "$(echo 'SELECT 1;' | run_for ${arch} ./sqlite3 :memory:)" = 1 ]
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(run_for ${arch} ./homebox_runas 2>&1 || true)"
    echo "${usage}" | grep -q 'Usage: homebox_runas'
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_homebox ${arch}
        build_sqlite ${arch}
        build_runas ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/homebox/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp homebox sqlite3 homebox_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/homebox/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
