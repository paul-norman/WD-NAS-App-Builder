#!/bin/bash

# Prepares Radicale (CalDAV and CardDAV server) for the NAS - for the Intel models and the ARM ones: its own Python (a
# portable, relocatable build, python-build-standalone's) with Radicale and its packages installed into it (from
# static/radicale/requirements.txt: each version with its files' checksums - all pure Python, so the same files for
# both), plus:
#  - radicale_runas: switches to Radicale's own user (the NAS has no su or similar) before running it
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs laid out for 4KB ones crash
# there - as python-build-standalone's python3.14 is. So for them (as in the Python app) python3.14 is a small launcher
# calling libpython (which is laid out for 64KB pages), compiled with Zig for the NAS's glibc, as is the run-as helper
# (fully static). Every ARM file is checked for that layout (ci/check_arm_pages.py), and each architecture's Radicale is
# started (the ARM one with QEMU's emulator) and asked for a user's calendars, with the app's kind of password.

set -e
set -o pipefail
set -x

VERSION=3.9.2
# Radicale's own wheel, as PyPI publishes it
RADICALE_WHEEL_SHA256=88a28c460af1f1c09745fefe1fb91aaf1b631499240eaaef5796a347b4c965ba
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
# Each architecture's checksums, as python-build-standalone's SHA256SUMS publishes them
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# The ARM models' compiler (its release's checksum)
ZIG_VERSION=0.17.1
ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# The architectures built (each into packages/static/radicale/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools
OUTPUT_ROOT=/data/packages/static/radicale/${VERSION}
QEMU='qemu-arm -cpu cortex-a9 -L /armhf-root'
# Radicale's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/radicale/requirements.txt
SITE=lib/python3.14/site-packages

# Downloads a file into the current folder and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Prepares the tools in ${TOOLS_PATH}: uv, Zig (for the ARM models' launcher and helper), and Radicale with its packages
# in ${BUILD_PATH}/site (installed once: pure Python, for both architectures).
function prepare() {
    local uv=${TOOLS_PATH}/uv-x86_64-unknown-linux-musl/uv

    mkdir -p ${TOOLS_PATH}
    cd ${TOOLS_PATH}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" zig.tar.xz ${ZIG_SHA256}
    tar -xJf zig.tar.xz
    export PATH="${TOOLS_PATH}/zig-x86_64-linux-${ZIG_VERSION}:${PATH}"

    # The Intel Python, untouched: what the lock is resolved for, and what installs the packages
    mkdir -p ${BUILD_PATH}/amd64
    cd ${BUILD_PATH}/amd64
    build_python amd64

    # Radicale's lock, written once (see LOCK)
    cd ${TOOLS_PATH}

    if [ ! -f ${LOCK} ]; then
        echo "radicale==${VERSION}" > requirements.in
        ${uv} pip compile --quiet --python ${BUILD_PATH}/amd64/python/bin/python3 --only-binary :all: \
            --generate-hashes --no-header requirements.in -o ${LOCK}
    fi

    # The lock must hold Radicale's own published checksum
    grep -q "${RADICALE_WHEEL_SHA256}" ${LOCK}

    # Wheels only (nothing built here), checked against the lock
    ${uv} pip install --python ${BUILD_PATH}/amd64/python/bin/python3 --target ${BUILD_PATH}/site --only-binary :all: \
        --require-hashes -r ${LOCK}
    # (the scripts uv writes call the Intel Python by its build path: the app runs python3 -m radicale)
    rm -rf ${BUILD_PATH}/site/bin

    # Pure Python: nothing compiled for one processor in it
    if [ -n "$(find ${BUILD_PATH}/site -name '*.so*')" ]; then
        find ${BUILD_PATH}/site -name '*.so*'
        echo "Radicale's packages have compiled parts: they would be for one processor only"

        exit 1
    fi
}

# Puts an architecture's Python into the current folder, as ./python (the ARM one with its launcher), trimmed.
#
# $1 arch The architecture (amd64 or armhf)
function build_python() {
    local target=x86_64-unknown-linux-gnu
    local sha256=${PYTHON_SHA256}
    local lib=python/lib/python3.14

    if [ "$1" = armhf ]; then
        target=armv7-unknown-linux-gnueabihf
        sha256=${PYTHON_ARMHF_SHA256}
    fi

    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-${target}-install_only_stripped.tar.gz" \
        python.tar.gz ${sha256}
    tar -xzf python.tar.gz
    rm python.tar.gz

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS),
    # and the terminal database - whose folders differ only in case, which a Windows drive holding the repository can't
    # store
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${lib}/site-packages/pip \
        ${lib}/site-packages/pip-* python/lib/tcl* python/lib/tk* python/lib/itcl* python/lib/thread* \
        python/share/terminfo python/bin/idle3* python/bin/pip*
    rm -f ${lib}/lib-dynload/_tkinter*

    [ "$1" = armhf ] || return 0

    cat > launcher.c <<'C'
// python3.14 for the ARM models: runs Python as python3.14 itself does, from libpython (laid out for their kernels'
// large memory pages, where python-build-standalone's own python3.14 isn't)
extern int Py_BytesMain(int argc, char **argv);

int main(int argc, char **argv)
{
	return Py_BytesMain(argc, argv);
}
C
    zig cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 -O2 -s launcher.c -o python/bin/python3.14 \
        -Lpython/lib -lpython3.14 -Wl,-rpath,'$ORIGIN/../lib'
    rm launcher.c
}

# Adds Radicale and its packages to the Python in the current folder, with their bytecode compiled (by the Intel Python,
# for both: the same Python version, the same bytecode), and writes Radicale's version to ./version.
function add_radicale() {
    cp -a ${BUILD_PATH}/site/. python/${SITE}/
    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${BUILD_PATH}/amd64/python/bin/python3 -m compileall -q python/lib/python3.14 > /dev/null || true
    printf '%s\n' "${VERSION}" > version
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > radicale_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: radicale_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("radicale_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("radicale_runas: could not run the program");
	return 127;
}
C
    if [ "$1" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s -o radicale_runas radicale_runas.c
    else
        gcc -O2 -static -s -o radicale_runas radicale_runas.c
    fi

    rm radicale_runas.c
}

# Checks an architecture's build in the current folder: (ARM) laid out for large memory pages; Python and the helper
# running; and Radicale started in a scratch folder, with a user whose password is a SHA-512 crypt hash (as the app
# writes them - checked by libpass's own Python code, Python 3.14 having no crypt module): its calendars listed with
# that password, refused without it.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local run=''
    local data=${BUILD_PATH}/check-$1
    local result pid code attempt

    if [ "$1" = armhf ]; then
        python3 /data/ci/check_arm_pages.py python radicale_runas
        run=${QEMU}
    fi

    ${run} python/bin/python3 -c 'import sys, ssl; print(sys.version.split()[0], ssl.OPENSSL_VERSION)'
    ${run} python/bin/python3 -c 'import radicale; print("Radicale", radicale.VERSION)'
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${run} ./radicale_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: radicale_runas'

    mkdir -p ${data}/collections
    ${run} python/bin/python3 -c 'import sys; from passlib.hash import sha512_crypt
print("check:" + sha512_crypt.using(rounds=5000).hash(sys.argv[1]))' 'Check.Password-1' > ${data}/users
    cat > ${data}/config <<EOF
[server]
hosts = 127.0.0.1:5232
[auth]
type = htpasswd
htpasswd_filename = ${data}/users
htpasswd_encryption = autodetect
[storage]
filesystem_folder = ${data}/collections
EOF
    ${run} python/bin/python3 -m radicale -C ${data}/config > ${data}.log 2>&1 &
    pid=$!
    code=''

    for attempt in $(seq 1 120); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -u check:Check.Password-1 -X PROPFIND -H 'Depth: 1' \
            http://127.0.0.1:5232/check/ || true)"
        [ "${code}" = 207 ] && break
        sleep 1
    done

    result="$(curl -s -o /dev/null -w '%{http_code}' -u check:wrong -X PROPFIND http://127.0.0.1:5232/check/ || true)"
    kill ${pid}
    wait ${pid} || true

    if [ "${code}" != 207 ] || [ "${result}" != 401 ]; then
        echo "Radicale's check failed: ${code} with the password, ${result} without"
        cat ${data}.log

        exit 1
    fi
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    prepare

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        # (the Intel Python is prepare's, untouched until now)
        [ -d python ] || build_python ${arch}
        add_radicale
        build_runas ${arch}
        check ${arch}

        # Nothing may differ only in case (see build_python)
        if [ -n "$(find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
            find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d
            echo 'These paths differ only in case'

            exit 1
        fi

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=${OUTPUT_ROOT}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp -a python radicale_runas version ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/radicale/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/radicale/requirements.txt
}

run
