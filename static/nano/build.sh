#!/bin/bash

# Builds nano fully static (musl), with ncurses built in - for the Intel models and the ARM ones. Zig compiles both for
# each (its own musl; for the ARM models' ARMv7 processors, hard-float, laid out for their kernels' large memory pages -
# 32KB on the EX2 Ultra), ncurses' helper programs are built for this machine with gcc, and the ARM build is checked for
# that layout (ci/check_arm_pages.py) and run with QEMU's emulator.

set -e
set -o pipefail
set -x

NCURSES_VERSION=6.6
VERSION=9.3
# Each checked against its maker's signature (Thomas Dickey's 19882D92DDA4C400C22C0D56CC2AF4472167BE03; nano's Benno
# Schulenberg 168E6F4297BFD7A79AFD4496514BBE2EB8E1961F, also in GNU's keyring)
NCURSES_SHA256=355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11
NANO_SHA256=a9affc52c9596ee0682bcdd4ceb3c0b235eb221d83d733dfd9b0dff45897cb0d
# The architectures built (each into packages/static/nano/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=/build/tools
OUTPUT_ROOT=/data/packages/static/nano/${VERSION}

# Writes each architecture's compiler commands (Zig's): <arch>-cc, <arch>-ar and <arch>-ranlib.
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    printf '#!/bin/sh\nexec zig cc -target x86_64-linux-musl -O2 "$@"\n' > ${TOOLS_PATH}/amd64-cc
    printf '#!/bin/sh\nexec zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 "$@"\n' > ${TOOLS_PATH}/armhf-cc

    for arch in amd64 armhf; do
        printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/${arch}-ar
        printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/${arch}-ranlib
    done

    chmod 755 ${TOOLS_PATH}/*
}

# Zig's target name for an architecture.
#
# $1 arch The architecture (amd64 or armhf)
#
# Prints it
function host_for() {
    if [ "$1" = armhf ]; then
        echo arm-linux-musleabihf
    else
        echo x86_64-linux-musl
    fi
}

# Builds ncurses (static) for an architecture into ${BUILD_PATH}/<arch>/ncurses-install. The common terminal types are
# built in (--with-fallbacks, from this machine's terminfo): the NAS has hardly any terminfo files, so e.g. SSH clients
# announcing xterm-256color would otherwise stop nano from starting. Others are looked for in the usual folders, and
# Entware's.
#
# $1 arch The architecture (amd64 or armhf)
function build_ncurses() {
    local arch="$1"

    cd ${BUILD_PATH}/${arch}
    tar -xzf ${BUILD_PATH}/ncurses-${NCURSES_VERSION}.tar.gz
    cd ncurses-${NCURSES_VERSION}
    CC=${TOOLS_PATH}/${arch}-cc AR=${TOOLS_PATH}/${arch}-ar RANLIB=${TOOLS_PATH}/${arch}-ranlib CFLAGS='-fPIC' \
        ./configure \
        --build=x86_64-alpine-linux-musl \
        --host=$(host_for ${arch}) \
        --with-build-cc=gcc \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --disable-stripping \
        --with-normal \
        --without-debug \
        --without-ada \
        --without-cxx-binding \
        --without-progs \
        --without-tests \
        --with-default-terminfo=/usr/share/terminfo \
        --with-terminfo-dirs='/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo:/opt/share/terminfo' \
        --with-fallbacks='xterm-256color,xterm,screen-256color,screen,tmux-256color,tmux,linux,vt100,vt220,ansi'
    make -j "$(nproc)" libs
    make DESTDIR="${BUILD_PATH}/${arch}/ncurses-install" install.libs install.includes
}

# Builds nano for an architecture (fully static), into ${BUILD_PATH}/<arch>/nano.
#
# $1 arch The architecture (amd64 or armhf)
function build_nano() {
    local arch="$1"
    local deps=${BUILD_PATH}/${arch}/ncurses-install/usr

    cd ${BUILD_PATH}/${arch}
    tar -xJf ${BUILD_PATH}/nano-${VERSION}.tar.xz
    cd nano-${VERSION}
    CC=${TOOLS_PATH}/${arch}-cc AR=${TOOLS_PATH}/${arch}-ar RANLIB=${TOOLS_PATH}/${arch}-ranlib CFLAGS='-fPIC' \
        CPPFLAGS="-I${deps}/include" LDFLAGS="-static -L${deps}/lib" \
        ./configure --build=x86_64-alpine-linux-musl --host=$(host_for ${arch}) --disable-nls \
        --disable-dependency-tracking
    make -j "$(nproc)"

    if [ "${arch}" = armhf ]; then
        arm-none-eabi-strip -o ${BUILD_PATH}/${arch}/nano src/nano
    else
        strip -o ${BUILD_PATH}/${arch}/nano src/nano
    fi
}

# Checks a build: fully static, and it runs (the ARM one laid out for large memory pages, and run with QEMU).
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local nano=${BUILD_PATH}/${arch}/nano
    local version

    if ! file ${nano} | grep -E 'statically linked|static-pie linked' > /dev/null; then
        echo "nano (${arch}) isn't static: $(file ${nano})"

        exit 1
    fi

    if [ "${arch}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${nano}
        version="$(qemu-arm -cpu cortex-a9 ${nano} --version)"
    else
        version="$(${nano} --version)"
    fi

    echo "${version}"
    echo "${version}" | grep "GNU nano, version ${VERSION}" > /dev/null
}

function run() {
    local arch

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    # (a pinned version: the unversioned ncurses.tar.gz always points at the newest release)
    sh /data/static/fetch.sh "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz" \
        ncurses-${NCURSES_VERSION}.tar.gz "${NCURSES_SHA256}"
    sh /data/static/fetch.sh "https://www.nano-editor.org/dist/v${VERSION%.*}/nano-${VERSION}.tar.xz" \
        nano-${VERSION}.tar.xz "${NANO_SHA256}"
    make_tools

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        build_ncurses ${arch}
        build_nano ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        rm -rf ${OUTPUT_ROOT}/${arch}
        mkdir -p ${OUTPUT_ROOT}/${arch}
        cp ${BUILD_PATH}/${arch}/nano ${OUTPUT_ROOT}/${arch}/
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
