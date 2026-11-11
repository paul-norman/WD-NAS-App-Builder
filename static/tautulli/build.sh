#!/bin/bash

# Prepares Tautulli for the NAS: its own Python (a portable, relocatable build), Tautulli itself (pure Python, with
# the packages it uses in its own lib/ folder - nothing to install), plus:
#  - tautulli_runas: switches to Tautulli's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=2.19.0
# Tautulli's release has no source archive of its own: GitHub's archive of its tag, pinned here
TAUTULLI_SHA256=e336b4e862a1959099b1058ef21624f24db261a81751b586ebb76807f7a9cb4e
# Tautulli needs Python 3.11 or later (its own tests run on 3.11 and 3.14)
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/tautulli/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

function build_python() {
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS),
    # and the terminal database - whose folders differ only in case, which a Windows drive holding the repository can't
    # store
    local lib=${BUILD_PATH}/python/lib/python3.14
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${lib}/site-packages/pip \
        ${lib}/site-packages/pip-* ${BUILD_PATH}/python/lib/tcl* ${BUILD_PATH}/python/lib/tk* \
        ${BUILD_PATH}/python/lib/itcl* ${BUILD_PATH}/python/lib/thread* ${BUILD_PATH}/python/share/terminfo \
        ${BUILD_PATH}/python/bin/idle3* ${BUILD_PATH}/python/bin/pip*
    rm -f ${lib}/lib-dynload/_tkinter*
}

function build_tautulli() {
    fetch "https://github.com/Tautulli/Tautulli/archive/refs/tags/v${VERSION}.tar.gz" tautulli.tar.gz ${TAUTULLI_SHA256}
    tar -xzf tautulli.tar.gz
    mv Tautulli-${VERSION} tautulli
    # Its version and branch, as Tautulli reads them for a "source" install (and its Docker image writes them)
    echo "v${VERSION}" > tautulli/version.txt
    echo 'master' > tautulli/branch.txt
    # Not needed to run it: other platforms' packaging, its repository's own files
    rm -rf tautulli/.github tautulli/snap tautulli/package tautulli/contrib tautulli/init-scripts tautulli/Dockerfile \
        tautulli/start.bat tautulli/.dockerignore tautulli/.gitignore tautulli/pylintrc
    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${BUILD_PATH}/python/bin/python3 -m compileall -q tautulli ${BUILD_PATH}/python/lib/python3.14 > /dev/null || true
}

function build_runas() {
    cd ${BUILD_PATH}
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
    gcc -O2 -static -o tautulli_runas tautulli_runas.c
    strip tautulli_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_python
    build_tautulli
    build_runas

    # Nothing may differ only in case (see build_python)
    if [ -n "$(find ${BUILD_PATH}/python ${BUILD_PATH}/tautulli | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${BUILD_PATH}/python ${BUILD_PATH}/tautulli | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${BUILD_PATH}/python ${BUILD_PATH}/tautulli ${BUILD_PATH}/tautulli_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/python/bin/python3 --version
    cat ${OUTPUT_PATH}/tautulli/version.txt
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
