#!/bin/bash

# Prepares Tautulli for the NAS - for the Intel models and the ARM ones: its own Python (a portable, relocatable build,
# python-build-standalone's), Tautulli itself (pure Python, with the packages it uses in its own lib/ folder - nothing
# to install), plus:
#  - tautulli_runas: switches to Tautulli's own user (the NAS has no su or similar) before running it
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs laid out for 4KB ones crash
# there - as python-build-standalone's python3.14 is. So for them (as in the Python app) python3.14 is a small launcher
# calling libpython (which is laid out for 64KB pages), compiled with Zig for the NAS's glibc, as is the run-as helper
# (fully static). Every ARM file is checked for that layout (ci/check_arm_pages.py), and Tautulli is started with
# QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=2.19.1
# Tautulli's release has no source archive of its own: GitHub's archive of its tag, pinned here
TAUTULLI_SHA256=a655a30d54216d604d0e65a390f609fa9d53f9ea1655efa5aa7902127512dca7
# Tautulli needs Python 3.11 or later (its own tests run on 3.11 and 3.14)
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
# Each architecture's checksums, as python-build-standalone's SHA256SUMS publishes them
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
# The ARM models' compiler (its release's checksum)
ZIG_VERSION=0.17.1
ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# The architectures built (each into packages/static/tautulli/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools
OUTPUT_ROOT=/data/packages/static/tautulli/${VERSION}
QEMU='qemu-arm -cpu cortex-a9 -L /armhf-root'

# Downloads a file into the current folder and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Prepares Zig (for the ARM models' launcher and helper) and Tautulli's source, in ${TOOLS_PATH} and ${BUILD_PATH}.
function prepare() {
    mkdir -p ${TOOLS_PATH}
    cd ${TOOLS_PATH}
    fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" zig.tar.xz ${ZIG_SHA256}
    tar -xJf zig.tar.xz
    export PATH="${TOOLS_PATH}/zig-x86_64-linux-${ZIG_VERSION}:${PATH}"

    cd ${BUILD_PATH}
    fetch "https://github.com/Tautulli/Tautulli/archive/refs/tags/v${VERSION}.tar.gz" tautulli.tar.gz ${TAUTULLI_SHA256}
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

# Puts Tautulli into the current folder, as ./tautulli, with its bytecode compiled (by the Intel Python, for both: the
# same Python version, the same bytecode).
function build_tautulli() {
    tar -xzf ${BUILD_PATH}/tautulli.tar.gz
    mv Tautulli-${VERSION} tautulli
    # Its version and branch, as Tautulli reads them for a "source" install (and its Docker image writes them)
    echo "v${VERSION}" > tautulli/version.txt
    echo 'master' > tautulli/branch.txt
    # Not needed to run it: other platforms' packaging, its repository's own files
    rm -rf tautulli/.github tautulli/snap tautulli/package tautulli/contrib tautulli/init-scripts tautulli/Dockerfile \
        tautulli/start.bat tautulli/.dockerignore tautulli/.gitignore tautulli/pylintrc

    # Pure Python: nothing compiled for one processor in it
    if [ -n "$(find tautulli -name '*.so*')" ]; then
        find tautulli -name '*.so*'
        echo 'Tautulli has compiled parts: they would be for one processor only'

        exit 1
    fi

    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${BUILD_PATH}/amd64/python/bin/python3 -m compileall -q tautulli python/lib/python3.14 > /dev/null || true
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > tautulli_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: tautulli_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("tautulli_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("tautulli_runas: could not run the program");
	return 127;
}
C
    if [ "$1" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s -o tautulli_runas tautulli_runas.c
    else
        gcc -O2 -static -s -o tautulli_runas tautulli_runas.c
    fi

    rm tautulli_runas.c
}

# Checks an architecture's build in the current folder: (ARM) laid out for large memory pages; Python and the helper
# running; and (ARM, with QEMU) Tautulli started in a scratch folder, serving its web interface.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local run=''
    local data=${BUILD_PATH}/check-$1
    local result pid page attempt

    if [ "$1" = armhf ]; then
        python3 /data/ci/check_arm_pages.py python tautulli_runas
        run=${QEMU}
    fi

    ${run} python/bin/python3 -c 'import sys, ssl, sqlite3; print(sys.version.split()[0], ssl.OPENSSL_VERSION)'
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${run} ./tautulli_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: tautulli_runas'

    [ "$1" = armhf ] || return 0

    # (started directly, so that stopping it stops Tautulli itself)
    mkdir -p ${data}
    HOME=${data} ${run} python/bin/python3 tautulli/Tautulli.py --datadir ${data} --nolaunch --nofork --port 8181 \
        > ${data}.log 2>&1 &
    pid=$!
    page=''

    for attempt in $(seq 1 180); do
        page="$(wget -qO- http://127.0.0.1:8181/ 2>/dev/null || true)"
        [ -n "${page}" ] && break
        sleep 1
    done

    kill ${pid}
    wait ${pid} || true

    if ! echo "${page}" | grep -q 'Tautulli'; then
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
        build_python ${arch}
        build_tautulli
        build_runas ${arch}
        check ${arch}

        # Nothing may differ only in case (see build_python)
        if [ -n "$(find python tautulli | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
            find python tautulli | tr '[:upper:]' '[:lower:]' | sort | uniq -d
            echo 'These paths differ only in case'

            exit 1
        fi

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=${OUTPUT_ROOT}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp -a python tautulli tautulli_runas ${output}/
        cat ${output}/tautulli/version.txt
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/tautulli/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
