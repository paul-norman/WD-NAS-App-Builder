#!/bin/bash

# Prepares Python for the NAS - for the Intel models and the ARM ones: a portable build of Python (python-build-standalone
# - the builds uv uses), relocatable and depending only on the NAS's glibc (2.17 or newer), plus uv (a static program)
# for virtual environments and packages. Both are downloaded and checked against their published checksums, and trimmed.
#
# The ARM models: python-build-standalone's python3.14 has a segment added after linking that's laid out for 4KB memory
# pages, and the ARM models' kernels use larger ones (32KB on the EX2 Ultra: it would crash there). Its libpython is laid
# out for 64KB pages, so python3.14 is replaced by a small launcher of the same name calling it (Py_BytesMain - what
# python3.14 itself runs), compiled with Zig for the NAS's glibc (2.17 symbols) and laid out for 64KB pages. Every ARM
# file is checked for that layout (ci/check_arm_pages.py), and Python is run with QEMU's emulator. uv's own ARM release
# is laid out for 4KB pages too, so the ARM build has no uv (pip and venv work without it).

set -e
set -o pipefail
set -x

# Python's version (the app's), and the python-build-standalone release with it
VERSION=3.14.10
PYTHON_RELEASE=20261026
# Each architecture's checksums, as the releases publish them (python-build-standalone's SHA256SUMS, uv's .sha256)
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
UV_ARMHF_SHA256=b215398c886e8cc2cfa282fe346c02025957f8633b75a3d4fd848e0adda4eddd
# The architectures built (each into packages/static/python/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
OUTPUT_ROOT=/data/packages/static/python/${VERSION}

# Downloads Python and uv for an architecture into the current folder, and puts them together as ./python, trimmed.
#
# $1 arch The architecture (amd64 or armhf)
function prepare() {
    local python_target uv_target python_sha256 uv_sha256 python_file

    if [ "$1" = armhf ]; then
        python_target=armv7-unknown-linux-gnueabihf
        uv_target=armv7-unknown-linux-musleabihf
        python_sha256="${PYTHON_ARMHF_SHA256}"
        uv_sha256="${UV_ARMHF_SHA256}"
    else
        python_target=x86_64-unknown-linux-gnu
        uv_target=x86_64-unknown-linux-musl
        python_sha256="${PYTHON_SHA256}"
        uv_sha256="${UV_SHA256}"
    fi

    python_file="cpython-${VERSION}+${PYTHON_RELEASE}-${python_target}-install_only_stripped.tar.gz"
    sh /data/static/fetch.sh \
        "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${python_file}" \
        python.tar.gz "${python_sha256}"
    if [ "$1" != armhf ]; then
        sh /data/static/fetch.sh \
            "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_target}.tar.gz" uv.tar.gz \
            "${uv_sha256}"
    fi
    tar -xzf python.tar.gz

    # (not uv's ARM release: laid out for 4KB pages)
    if [ "$1" != armhf ]; then
        tar -xzf uv.tar.gz
        mv "uv-${uv_target}/uv" "uv-${uv_target}/uvx" python/bin/
    fi
    # Not needed: the terminal database (Python 3.14's prompt has its own; its folders also differ only in case, which a
    # Windows drive holding the repository can't store) and IDLE (needs a desktop)
    rm -rf python/share/terminfo python/lib/python3*/idlelib python/bin/idle3*
    # Packages installed into the app's Python itself would be lost with its next update: pip points to virtual
    # environments
    cp /data/apps/python/EXTERNALLY-MANAGED python/lib/python3*/
}

# Replaces the ARM build's python3.14 with a launcher calling its libpython (in the current folder's ./python).
function arm_launcher() {
    local series="${VERSION%.*}"

    cat > launcher.c <<'C'
// python3.14 for the ARM models: runs Python as python3.14 itself does, from libpython (laid out for their kernels'
// large memory pages, where python-build-standalone's own python3.14 isn't)
extern int Py_BytesMain(int argc, char **argv);

int main(int argc, char **argv)
{
	return Py_BytesMain(argc, argv);
}
C
    zig cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 -O2 -s launcher.c -o "python/bin/python${series}" \
        -Lpython/lib -l"python${series}" -Wl,-rpath,'$ORIGIN/../lib'
}

# Checks a build: the ARM one's layout, then that Python runs with what the app relies on (ssl, sqlite3, venv), and uv -
# in the Debian stage, as the NAS's stand-in (the ARM one with QEMU, on Debian's ARM glibc).
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local run bin result

    # The Intel build in the Debian stage (this image's own is musl, not glibc), with chroot
    rm -rf /armhf-root/work
    mkdir -p /armhf-root/work
    cp -a python /armhf-root/work/
    run='chroot /armhf-root'
    bin=/work/python/bin

    if [ "$1" = armhf ]; then
        python3 /data/ci/check_arm_pages.py python
        # (QEMU runs it from this image, with its ARM glibc from the Debian stage)
        run='qemu-arm -cpu cortex-a9 -L /armhf-root'
        bin=/armhf-root/work/python/bin
    fi

    result="$(${run} ${bin}/python3 -c 'import sys, ssl, sqlite3, venv, ctypes, hashlib, lzma, zlib, asyncio
print(sys.version.split()[0], sys.prefix.endswith("/python"), ssl.OPENSSL_VERSION.split()[0],
      hashlib.sha256(b"abc").hexdigest()[:8], asyncio.run(asyncio.sleep(0, result="async")))')"
    echo "${result}"
    [ "${result}" = "${VERSION} True OpenSSL ba7816bf async" ]
    if [ "$1" != armhf ]; then
        ${run} ${bin}/uv --version | grep "uv ${UV_VERSION}" > /dev/null
    fi

    rm -rf /armhf-root/work
}

function run() {
    local arch

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        prepare ${arch}

        if [ "${arch}" = armhf ]; then
            arm_launcher
        fi

        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        rm -rf ${OUTPUT_ROOT}/${arch}
        mkdir -p ${OUTPUT_ROOT}/${arch}
        cp -a python ${OUTPUT_ROOT}/${arch}/
        du -sh ${OUTPUT_ROOT}/${arch}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
