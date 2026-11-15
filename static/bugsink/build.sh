#!/bin/bash

# Prepares Bugsink for the NAS - for the Intel models and the ARM ones: its own Python (a portable, relocatable build,
# python-build-standalone's) with Bugsink and its packages installed into it (from static/bugsink/requirements.txt:
# each version with its files' checksums), plus:
#  - bugsink_runas: switches to Bugsink's own user (the NAS has no su or similar) before running it
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs and libraries laid out for 4KB
# ones crash there - as python-build-standalone's python3.14 and PyPI's ARM wheels are. So, for them (as for the Python
# app): python3.14 is a small launcher calling libpython (which is laid out for 64KB pages), compiled with Zig; the
# packages that are pure Python are PyPI's own (checked against the lock's checksums), as are charset-normalizer's and
# PyYAML's pure Python versions (without their optional compiled parts); and the ones with compiled parts in Rust
# (ARM_BUILT) are built here from their source (checked the same way) with maturin, Zig linking them for glibc 2.17.
# Every ARM file is checked for that layout (ci/check_arm_pages.py), and Bugsink's packages are run with QEMU's
# emulator.

set -e
set -o pipefail
set -x

VERSION=2.6.3
# Bugsink's own wheel, as PyPI publishes it
BUGSINK_WHEEL_SHA256=a3ebae8ef794c105b181b62764fb8a02018f9368313c75b5a5abfdbe442744ce
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
# Each architecture's checksums, as python-build-standalone's SHA256SUMS publishes them
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# The ARM models' Rust packages' builder, and the linker it uses (as their releases publish their checksums)
MATURIN_VERSION=1.16.0
MATURIN_SHA256=804add817bf3b8a3760324ace2e2c39c345f7a99b3ace1296aeed1abc3a1d8c4
ZIG_VERSION=0.17.1
ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# The packages built from their source for the ARM models (their compiled parts are in Rust), and those installed there
# as pure Python (PyPI's wheel without compiled parts, or - for PyYAML, which has none - one made from its source)
ARM_BUILT='brotli-rs rpds-py symalot'
ARM_PURE_SOURCE='pyyaml'
# The newest glibc symbol versions the NAS has (OS5: glibc 2.31 on the Intel models; the ARM build is held to 2.17,
# python-build-standalone's own)
NAS_GLIBC=2.31
NAS_GLIBC_ARMHF=2.17
# The architectures built (each into packages/static/bugsink/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools
OUTPUT_ROOT=/data/packages/static/bugsink/${VERSION}
# Bugsink's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/bugsink/requirements.txt

# Downloads a file into the current folder and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Prepares the tools: uv, an untouched Intel Python (its pip assembles the ARM packages) and, for the ARM packages,
# maturin and Zig - in ${TOOLS_PATH}.
function build_tools() {
    mkdir -p ${TOOLS_PATH}
    cd ${TOOLS_PATH}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz
    fetch "https://github.com/PyO3/maturin/releases/download/v${MATURIN_VERSION}/maturin-x86_64-unknown-linux-musl.tar.gz" \
        maturin.tar.gz ${MATURIN_SHA256}
    tar -xzf maturin.tar.gz
    fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" zig.tar.xz ${ZIG_SHA256}
    tar -xJf zig.tar.xz
    mkdir -p bin
    mv maturin bin/
    ln -s ${TOOLS_PATH}/zig-x86_64-linux-${ZIG_VERSION}/zig bin/zig
    export PATH="${TOOLS_PATH}/bin:${PATH}"

    # Bugsink's lock, written once (see LOCK)
    if [ ! -f ${LOCK} ]; then
        echo "bugsink==${VERSION}" > requirements.in
        ./uv-x86_64-unknown-linux-musl/uv pip compile --quiet --python ${TOOLS_PATH}/python/bin/python3 \
            --generate-hashes --no-header requirements.in -o ${LOCK}
    fi

    # The lock must hold Bugsink's own published checksum
    grep -q "${BUGSINK_WHEEL_SHA256}" ${LOCK}
}

# Puts an architecture's Python into the current folder, as ./python (the ARM one with its launcher).
#
# $1 arch The architecture (amd64 or armhf)
function build_python() {
    if [ "$1" != armhf ]; then
        cp -a ${TOOLS_PATH}/python python

        return
    fi

    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_ARMHF_SHA256}
    tar -xzf python.tar.gz
    rm python.tar.gz

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
}

# Writes the lock's entries for some packages (or for all but them) to a file.
#
# $1 mode     only or except
# $2 file     The file written
# $@ packages Their names
function lock_part() {
    local mode="$1"
    local file="$2"
    shift 2

    python3 - "${LOCK}" "${mode}" "$@" > "${file}" <<'PY'
import re
import sys

lock, mode, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
entry = None

for line in open(lock, encoding="utf-8"):
    match = re.match(r"^([A-Za-z0-9_.-]+)==", line)

    if match:
        entry = re.sub(r"[-_.]+", "-", match.group(1)).lower()

    if not line.startswith(("#", " ")) and not match:
        entry = None

    # (the entries' "# via" comments are left out)
    if entry and not line.lstrip().startswith("#") and (entry in names) == (mode == "only"):
        print(line, end="")
PY
}

# Installs Bugsink and its packages into the Intel Python (./python), from the lock.
function install_intel() {
    ${TOOLS_PATH}/uv-x86_64-unknown-linux-musl/uv pip install --python python/bin/python3 --break-system-packages \
        --require-hashes -r ${LOCK}
}

# Installs Bugsink and its packages into the ARM Python (./python): PyPI's pure Python wheels, and wheels made here from
# their source for the rest - every download checked against the lock's checksums.
function install_arm() {
    local pip="${TOOLS_PATH}/python/bin/python3 -m pip --disable-pip-version-check"
    local site=${PWD}/python/lib/python3.14/site-packages
    local wheels=${PWD}/wheels
    local package source

    mkdir -p ${wheels} sources
    # shellcheck disable=SC2086
    lock_part except pure.txt ${ARM_BUILT} ${ARM_PURE_SOURCE}
    # shellcheck disable=SC2086
    lock_part only built.txt ${ARM_BUILT} ${ARM_PURE_SOURCE}
    ${pip} download --no-deps --require-hashes --only-binary :all: --platform any --python-version 3.14 \
        --implementation py --abi none -d ${wheels} -r pure.txt
    # (their sources - only theirs: their build tools may be wheels)
    ${pip} download --no-deps --require-hashes --no-binary "$(echo ${ARM_BUILT} ${ARM_PURE_SOURCE} | tr ' ' ,)" \
        -d sources -r built.txt

    for package in ${ARM_PURE_SOURCE}; do
        source="$(ls sources/${package}-*.tar.gz)"
        ${pip} wheel --no-deps -w pure-wheels "${source}"
    done

    # (PyYAML's own build tags its wheel for this machine even when, as here, it has no compiled part)
    ${pip} install --quiet wheel
    for source in pure-wheels/*.whl; do
        if python3 -m zipfile -l "${source}" | grep -q '\.so'; then
            echo "${source} has a compiled part: it would be this machine's"

            exit 1
        fi

        ${TOOLS_PATH}/python/bin/python3 -m wheel tags --python-tag py3 --abi-tag none --platform-tag any \
            --remove "${source}"
    done
    mv pure-wheels/*.whl ${wheels}/

    for package in ${ARM_BUILT}; do
        source="$(ls sources/${package//-/[-_]}-*.tar.gz)"
        mkdir -p "build-${package}"
        tar -xzf "${source}" -C "build-${package}" --strip-components=1
        (
            cd "build-${package}"
            PYO3_CROSS_LIB_DIR=${PWD%/*}/python/lib PYO3_CROSS_PYTHON_VERSION=3.14 maturin build --release \
                --target armv7-unknown-linux-gnueabihf --zig --compatibility manylinux2014 -o ${wheels}
        )
    done

    ${pip} install --no-deps --no-index --only-binary :all: --target ${site} --python-version 3.14 \
        --implementation cp --abi cp314 --abi abi3 --abi none --platform manylinux2014_armv7l \
        --platform manylinux_2_17_armv7l --platform linux_armv7l --platform any ${wheels}/*.whl
    # (no scripts: the app runs Bugsink with python -m)
    rm -rf ${site}/bin

    # Every package in the lock, installed (besides the pip python-build-standalone comes with)
    [ "$(ls -d ${site}/*.dist-info | grep -cv '/pip-')" = "$(grep -cE '^[A-Za-z0-9_.-]+==' ${LOCK})" ]
}

# Trims an architecture's Python (./python) to what a server needs, and compiles its bytecode.
#
# $1 arch The architecture (amd64 or armhf)
function trim() {
    local lib=python/lib/python3.14
    local strip=strip

    [ "$1" = armhf ] && strip=arm-linux-gnueabihf-strip
    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS),
    # and the terminal database - whose folders differ only in case, which a Windows drive holding the repository can't
    # store
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${lib}/site-packages/pip \
        ${lib}/site-packages/pip-* python/lib/tcl* python/lib/tk* python/lib/itcl* python/lib/thread* \
        python/share/terminfo python/bin/idle3* python/bin/pip*
    rm -f ${lib}/lib-dynload/_tkinter*
    # The packages' compiled parts without their debugging symbols (symalot's alone: 55MB, then 4MB)
    find ${lib}/site-packages -name '*.so' -exec ${strip} --strip-unneeded {} +
    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user) - by the Intel
    # Python for both (the same Python version: the same bytecode)
    ${TOOLS_PATH}/python/bin/python3 -m compileall -q ${lib} > /dev/null || true
}

# Checks that every compiled part of an architecture's Python (./python) runs with the NAS's glibc.
#
# $1 arch The architecture (amd64 or armhf)
function check_glibc() {
    local objdump=objdump
    local newest=${NAS_GLIBC}
    local found=0
    local file version

    if [ "$1" = armhf ]; then
        objdump=arm-linux-gnueabihf-objdump
        newest=${NAS_GLIBC_ARMHF}
    fi

    while read -r file; do
        head -c 4 "${file}" | grep -q ELF || continue

        for version in $(${objdump} -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${newest#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(find python -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${newest})"

        exit 1
    fi
}

# Checks an architecture's build in the current folder: (ARM) laid out for large memory pages, and Bugsink's packages
# importing and working - the ARM ones with QEMU, on Debian's ARM glibc.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local run=''
    local python=${PWD}/python/bin/python3
    local result

    if [ "$1" = armhf ]; then
        python3 /data/ci/check_arm_pages.py python bugsink_runas
        run='qemu-arm -cpu cortex-a9 -L /armhf-root'
    fi

    # (each package with compiled parts at work)
    result="$(${run} ${python} -c 'import bugsink, django, gunicorn, yaml, charset_normalizer, rpds, brotli_rs, symalot
data = b"bugsink " * 100
print(django.get_version(), rpds.HashTrieMap({"a": 1})["a"], brotli_rs.decompress(brotli_rs.compress(data)) == data,
      yaml.safe_load("a: [1, 2]")["a"][1], charset_normalizer.from_bytes("März".encode()).best().encoding)')"
    echo "${result}"
    echo "${result}" | grep -E '^[0-9.]+ 1 True 2 utf_8$' > /dev/null
    echo "${result}" | grep -q "^$(grep -o '^django==[0-9.]*' ${LOCK} | cut -d= -f3) "
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${run} ./bugsink_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: bugsink_runas'
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
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
    if [ "$1" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s -o bugsink_runas bugsink_runas.c
    else
        gcc -O2 -static -s -o bugsink_runas bugsink_runas.c
    fi
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_tools

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_python ${arch}

        if [ "${arch}" = armhf ]; then
            install_arm
        else
            install_intel
        fi

        trim ${arch}
        check_glibc ${arch}
        build_runas ${arch}
        check ${arch}

        # Nothing may differ only in case (see trim)
        if [ -n "$(find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
            find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d
            echo 'These paths differ only in case'

            exit 1
        fi

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=${OUTPUT_ROOT}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp -a python bugsink_runas ${output}/
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/bugsink/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/bugsink/requirements.txt
}

run
