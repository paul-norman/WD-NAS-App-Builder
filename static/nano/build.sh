#!/bin/bash

set -e
set -o pipefail
set -x

MUSL_VERSION=1.2.6
NCURSES_VERSION=6.6
VERSION=9.3

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/nano/${VERSION}/${ARCH}

function build_musl() {
    cd ${BUILD_PATH}

    # Download
    curl -LO https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz
    tar zxvf musl-${MUSL_VERSION}.tar.gz
    cd musl-${MUSL_VERSION}

    # Configure
    ./configure

    # Make
    make -j4
    make install
}

# The common terminal types are built in (--with-fallbacks, from the build machine's terminfo): the NAS has hardly any
# terminfo files, so e.g. SSH clients announcing xterm-256color would otherwise stop nano from starting. Others are
# looked for in the usual folders, and Entware's
function build_ncurses() {
    cd ${BUILD_PATH}

    # Download (a pinned version: the unversioned ncurses.tar.gz always points at the newest release)
    curl -LO https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz
    tar zxvf ncurses-${NCURSES_VERSION}.tar.gz
    cd ncurses-${NCURSES_VERSION}

    # Configure
    CC='/usr/local/musl/bin/musl-gcc -static' \
    CFLAGS='-fPIC' \
    ./configure \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --with-normal \
        --without-debug \
        --without-ada \
        --with-default-terminfo=/usr/share/terminfo \
        --with-terminfo-dirs='/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo:/opt/share/terminfo' \
        --with-fallbacks='xterm-256color,xterm,screen-256color,screen,tmux-256color,tmux,linux,vt100,vt220,ansi'

    # Make
    mkdir "${BUILD_PATH}/ncurses-install"
    make DESTDIR="${BUILD_PATH}/ncurses-install" \
        install.libs install.includes
}

function build_nano() {
    cd ${BUILD_PATH}

    # Download
    curl -LO https://www.nano-editor.org/dist/v${VERSION%.*}/nano-${VERSION}.tar.xz
    tar xJvf nano-${VERSION}.tar.xz
    cd nano-${VERSION}

    # Add in missing header from OS
    mkdir -p ${BUILD_PATH}/ncurses-install/usr/include/linux
    ln -sf /usr/include/linux/vt.h ${BUILD_PATH}/ncurses-install/usr/include/linux/vt.h

    # Configure
    CC='/usr/local/musl/bin/musl-gcc -static' \
    CFLAGS='-fPIC' \
    CPPFLAGS="-I${BUILD_PATH}/ncurses-install/usr/include" \
    LDFLAGS="-L${BUILD_PATH}/ncurses-install/usr/lib" \
    ./configure \
        --disable-nls \
        --disable-dependency-tracking

    # Make
    make -j4
    strip src/nano
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_musl
    build_ncurses
    build_nano

    # Copy to output
    mkdir -p $OUTPUT_PATH
    cp ${BUILD_PATH}/nano-${VERSION}/src/nano ${OUTPUT_PATH}/

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages
}

run
