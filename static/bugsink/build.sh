#!/bin/bash

# Prepares Bugsink for the NAS: its own Python (a portable, relocatable build) with Bugsink and its packages installed
# into it (from static/bugsink/requirements.txt: each version with its files' checksums), plus:
#  - bugsink_runas: switches to Bugsink's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=2.6.3
# Bugsink's own wheel, as PyPI publishes it
BUGSINK_WHEEL_SHA256=a3ebae8ef794c105b181b62764fb8a02018f9368313c75b5a5abfdbe442744ce
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# The newest glibc symbol version the NAS has (OS5: glibc 2.31)
NAS_GLIBC=2.31

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
PYTHON_PATH=${BUILD_PATH}/python
OUTPUT_PATH=/data/packages/static/bugsink/${VERSION}/${ARCH}
# Bugsink's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/bugsink/requirements.txt

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

function build_python() {
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
}

function build_bugsink() {
    local uv=${BUILD_PATH}/uv-x86_64-unknown-linux-musl/uv

    cd ${BUILD_PATH}

    if [ ! -f ${LOCK} ]; then
        echo "bugsink==${VERSION}" > requirements.in
        ${uv} pip compile --quiet --python ${PYTHON_PATH}/bin/python3 --generate-hashes --no-header requirements.in -o ${LOCK}
    fi

    # The lock must hold Bugsink's own published checksum
    grep -q "${BUGSINK_WHEEL_SHA256}" ${LOCK}
    ${uv} pip install --python ${PYTHON_PATH}/bin/python3 --break-system-packages --require-hashes -r ${LOCK}

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS),
    # and the terminal database - whose folders differ only in case, which a Windows drive holding the repository can't
    # store
    local lib=${PYTHON_PATH}/lib/python3.14
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${lib}/site-packages/pip \
        ${lib}/site-packages/pip-* ${PYTHON_PATH}/lib/tcl* ${PYTHON_PATH}/lib/tk* ${PYTHON_PATH}/lib/itcl* \
        ${PYTHON_PATH}/lib/thread* ${PYTHON_PATH}/share/terminfo ${PYTHON_PATH}/bin/idle3* ${PYTHON_PATH}/bin/pip*
    rm -f ${lib}/lib-dynload/_tkinter*
    # The packages' compiled parts without their debugging symbols (symbolic's alone: 55MB, then 4MB)
    find ${lib}/site-packages -name '*.so' -exec strip --strip-unneeded {} +
    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${PYTHON_PATH}/bin/python3 -m compileall -q ${lib} > /dev/null || true

    # Every compiled part must run with the NAS's glibc
    local found=0

    while read -r file; do
        head -c 4 "${file}" | grep -q ELF || continue

        for version in $(objdump -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${NAS_GLIBC#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(find ${PYTHON_PATH} -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${NAS_GLIBC})"

        exit 1
    fi
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > bugsink_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: bugsink_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("bugsink_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("bugsink_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o bugsink_runas bugsink_runas.c
    strip bugsink_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_python
    build_bugsink
    build_runas

    # Nothing may differ only in case (see build_bugsink)
    if [ -n "$(find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${PYTHON_PATH} ${BUILD_PATH}/bugsink_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/python/bin/python3 -c 'import bugsink, django; print("Bugsink", bugsink.__file__, "Django", django.get_version())'
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/bugsink/requirements.txt
}

run
