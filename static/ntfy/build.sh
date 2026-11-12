#!/bin/bash

# Prepares ntfy for the NAS - for the Intel models and the ARM ones - plus a fully static build of:
#  - ntfy_runas: switches to ntfy's own user (the NAS has no su or similar) before running it
#
# Intel: ntfy's official static program. ARM: built here from ntfy's source, as its official ARM program is linked for
# 4KB memory pages and the ARM models' kernels use larger ones (32KB on the EX2 Ultra: it crashes there) - its web app
# (npm, from its lock file) and documentation (mkdocs) first, as the official build embeds them, then ntfy itself for
# ARMv7 with Go, its C parts (SQLite) cross-compiled and the whole linked statically by Zig, which lays programs out for
# 64KB pages. Every ARM program is checked for that (ci/check_arm_pages.py) and run with QEMU's emulator: ntfy serves,
# takes a message and gives it back from its SQLite cache.

set -e
set -o pipefail
set -x

VERSION=2.37.2
# Each architecture's release, as its checksums.txt publishes it
NTFY_SHA256=e67f53d7fbed529b83faf3993b584110921ef3567b0ac0b033c6910879a4ffd1
# Its source (GitHub's archive of the release's tag), for the ARM build
NTFY_SOURCE_SHA256=4a61b0ddc74dacf386ed8f939bd59dfeab1091157d091285731fe3bd595cbcd2
# The documentation's tools (ntfy's requirements.txt doesn't pin them)
MKDOCS_VERSION=1.6.1
MKDOCS_MATERIAL_VERSION=9.8.1
MKDOCS_MINIFY_VERSION=0.8.0
# The architectures built (each into packages/static/ntfy/<version>/<arch>)
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

# Builds ntfy for the ARM models from its source, into the current folder: its web app and documentation (embedded in
# it), then ntfy with Go for ARMv7 - SQLite cross-compiled and everything linked statically by Zig (64KB pages).
function build_arm_ntfy() {
    local here="$(pwd)"
    local source="${here}/ntfy-${VERSION}"

    sh /data/static/fetch.sh "https://github.com/binwiederhier/ntfy/archive/refs/tags/v${VERSION}.tar.gz" source.tar.gz \
        "${NTFY_SOURCE_SHA256}"
    tar -xzf source.tar.gz

    cd "${source}/web"
    npm ci --no-audit --no-fund
    npm run build
    mv build/index.html build/app.html
    rm -rf ../server/site build/config.js
    mv build ../server/site

    cd "${source}"
    python3 -m venv /tmp/docs-venv
    /tmp/docs-venv/bin/pip install --no-cache-dir "mkdocs==${MKDOCS_VERSION}" \
        "mkdocs-material==${MKDOCS_MATERIAL_VERSION}" "mkdocs-minify-plugin==${MKDOCS_MINIFY_VERSION}"
    /tmp/docs-venv/bin/python -m mkdocs build

    CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7 CC='zig cc -target arm-linux-musleabihf -mcpu=cortex_a9' \
        go build -o "${here}/ntfy" -tags sqlite_omit_load_extension,osusergo,netgo \
        -ldflags "-linkmode=external -extldflags=-static -s -w -X main.version=${VERSION}"
    cd "${here}"
}

# Downloads ntfy's release for the Intel models into the current folder - or, for the ARM ones, builds it.
#
# $1 arch The architecture (amd64 or armhf)
function build_ntfy() {
    if [ "$1" = armhf ]; then
        build_arm_ntfy
    else
        sh /data/static/fetch.sh \
            "https://github.com/binwiederhier/ntfy/releases/download/v${VERSION}/ntfy_${VERSION}_linux_amd64.tar.gz" \
            ntfy.tar.gz "${NTFY_SHA256}"
        tar -xzf ntfy.tar.gz
        mv ntfy_${VERSION}_linux_amd64/ntfy ntfy
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > ntfy_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: ntfy_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("ntfy_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("ntfy_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o ntfy_runas ntfy_runas.c
}

# Checks the ARM build of ntfy (in the current folder) with QEMU's emulator: it serves its web app and documentation,
# takes a message, and gives it back from its SQLite cache.
function check_arm_serving() {
    local url=http://127.0.0.1:18080
    local pid i

    rm -rf /tmp/ntfy-test
    mkdir -p /tmp/ntfy-test
    qemu-arm -cpu cortex-a9 ./ntfy serve --listen-http 127.0.0.1:18080 --cache-file /tmp/ntfy-test/cache.db \
        --base-url ${url} > /tmp/ntfy-test/serve.log 2>&1 &
    pid=$!

    for i in $(seq 1 60); do
        curl -sf -o /dev/null ${url}/v1/health && break
        sleep 1
    done

    curl -sf ${url}/ | grep -i '<html' > /dev/null
    curl -sf ${url}/docs/ | grep -i 'ntfy' > /dev/null
    curl -sf -d 'Hello from ntfy on ARM' ${url}/armtest > /dev/null
    curl -sf "${url}/armtest/json?poll=1" | grep 'Hello from ntfy on ARM' > /dev/null
    [ -s /tmp/ntfy-test/cache.db ]
    kill ${pid}
    wait ${pid} 2> /dev/null || true
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
        build_ntfy ${arch}
        build_runas ${arch}

        if [ "${arch}" = armhf ]; then
            python3 /data/ci/check_arm_pages.py ntfy ntfy_runas
            check_arm_serving
        fi

        run_for ${arch} ./ntfy --help > /dev/null
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ./ntfy_runas 2>&1 || true)"
        echo "${usage}" | grep 'Usage: ntfy_runas' > /dev/null

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/ntfy/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp ntfy ntfy_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/ntfy/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
