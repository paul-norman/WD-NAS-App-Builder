#!/bin/bash

# Prepares Transmission (BitTorrent) for the NAS - for the Intel models and the ARM ones, every program fully static
# (musl), so nothing depends on the NAS's own libraries:
#  - transmission-daemon: the BitTorrent client, run in the background, with its web interface (in share/transmission)
#  - transmission-remote, -create, -edit, -show: its command-line tools
#  - tr_runas: switches to Transmission's own user (the NAS has no su or similar) before running it

# The Intel build uses gcc, with Alpine's static OpenSSL and zlib. The ARM one is cross-compiled on this (Intel) machine
# with Zig for the ARM models' ARMv7 processors (hard-float) - OpenSSL and zlib built from their source for it first,
# Transmission's own bundled libraries through its toolchain file - and checked for their kernels' large memory pages
# (ci/check_arm_pages.py). Each build is checked by starting the daemon (the ARM one with QEMU's emulator) and asking it
# for its session with transmission-remote.

set -e
set -o pipefail
set -x

VERSION=4.1.4
TRANSMISSION_SHA256=86e7aa020cdf64826447034bc85f4d3b7c848d8c0891d9dc9b9fddfb2c805d22
# curl, for trackers and web seeds over HTTP(S): built small (OpenSSL and zlib only)
CURL_VERSION=8.23.0
CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
# OpenSSL and zlib for the ARM build (as the Nginx app's: OpenSSL's published SHA256, zlib's signature by Mark Adler)
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
# The architectures built (each into packages/static/transmission/<version>/<arch>)
ARCHES='amd64 armhf'
ARM_HOST=arm-linux-musleabihf

BUILD_PATH=/build
TOOLS_PATH=/build/tools

# Downloads every source into ${BUILD_PATH}, each checked against its SHA256.
function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/transmission/transmission/releases/download/${VERSION}/transmission-${VERSION}.tar.xz" \
        transmission.tar.xz ${TRANSMISSION_SHA256}
    sh /data/static/fetch.sh "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" curl.tar.xz ${CURL_SHA256}
    sh /data/static/fetch.sh \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl.tar.gz "${OPENSSL_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        zlib.tar.gz "${ZLIB_SHA256}"
}

# Writes the ARM compiler's commands (Zig's, for the ARM models' processors) - arm-cc, arm-c++, arm-ar and arm-ranlib -
# and a CMake toolchain file using them (with QEMU to run anything a configure step runs).
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    printf '#!/bin/sh\nexec zig cc -target %s -mcpu=cortex_a9 "$@"\n' ${ARM_HOST} > ${TOOLS_PATH}/arm-cc
    printf '#!/bin/sh\nexec zig c++ -target %s -mcpu=cortex_a9 "$@"\n' ${ARM_HOST} > ${TOOLS_PATH}/arm-c++
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/arm-*

    cat > ${TOOLS_PATH}/arm.cmake <<CMAKE
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER ${TOOLS_PATH}/arm-cc)
set(CMAKE_CXX_COMPILER ${TOOLS_PATH}/arm-c++)
set(CMAKE_AR ${TOOLS_PATH}/arm-ar CACHE FILEPATH "")
set(CMAKE_RANLIB ${TOOLS_PATH}/arm-ranlib CACHE FILEPATH "")
set(CMAKE_CROSSCOMPILING_EMULATOR qemu-arm;-cpu;cortex-a9)
set(CMAKE_FIND_ROOT_PATH ${BUILD_PATH}/armhf/deps)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
}

# Builds zlib and OpenSSL (its libraries only) for the ARM models, static, into ${BUILD_PATH}/armhf/deps.
function build_arm_libraries() {
    local deps=${BUILD_PATH}/armhf/deps
    local tools="CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib"

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/zlib.tar.gz
    cd zlib-${ZLIB_VERSION}
    env ${tools} CFLAGS='-O2 -fPIC' ./configure --static --prefix=${deps}
    make -j "$(nproc)" libz.a
    make install

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/openssl.tar.gz
    cd openssl-${OPENSSL_VERSION}
    # Only the libraries (no programs, tests or documents), with no loadable modules or engines
    ./Configure linux-armv4 --prefix=${deps} --libdir=lib --openssldir=/etc/ssl -O2 \
        no-shared no-module no-engine no-apps no-tests no-docs ${tools}
    make -j "$(nproc)" build_libs
    make install_dev
}

# Builds a small static curl (OpenSSL and zlib only) for an architecture into ${BUILD_PATH}/<arch>/deps.
#
# $1 arch The architecture (amd64 or armhf)
function build_curl() {
    local arch="$1"
    local deps=${BUILD_PATH}/${arch}/deps
    local cross=''

    if [ "${arch}" = armhf ]; then
        cross="--build=x86_64-alpine-linux-musl --host=${ARM_HOST} --with-openssl=${deps} --with-zlib=${deps}"
        cross="${cross} CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib"
        # (the certificate authorities where the Intel build finds them: configure doesn't look when cross-compiling)
        cross="${cross} --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt"
    else
        cross='--with-openssl --with-zlib'
    fi

    cd ${BUILD_PATH}/${arch}
    tar -xf ${BUILD_PATH}/curl.tar.xz
    cd curl-${CURL_VERSION}
    # (the ARM build's OpenSSL and zlib found by pkg-config in its own folder only)
    PKG_CONFIG_LIBDIR=${deps}/lib/pkgconfig ./configure --prefix=${deps} --disable-shared --enable-static ${cross} \
        --without-libpsl --without-libidn2 --without-nghttp2 --without-nghttp3 --without-brotli --without-zstd \
        --without-libssh2 --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-docs \
        --disable-manual
    make -j "$(nproc)"
    make install
}

# Builds Transmission's daemon and tools for an architecture into ${BUILD_PATH}/<arch>/install.
#
# $1 arch The architecture (amd64 or armhf)
function build_transmission() {
    local arch="$1"
    local deps=${BUILD_PATH}/${arch}/deps
    # curl's own libraries (OpenSSL, zlib) go at the end of every link (CMake's FindCURL only names libcurl itself)
    local libraries='/usr/lib/libssl.a /usr/lib/libcrypto.a /usr/lib/libz.a'
    local cross=()

    if [ "${arch}" = armhf ]; then
        libraries="${deps}/lib/libssl.a ${deps}/lib/libcrypto.a ${deps}/lib/libz.a"
        cross=(-DCMAKE_TOOLCHAIN_FILE=${TOOLS_PATH}/arm.cmake -DOPENSSL_ROOT_DIR=${deps})
    fi

    cd ${BUILD_PATH}/${arch}
    tar -xf ${BUILD_PATH}/transmission.tar.xz
    cd transmission-${VERSION}

    # Only the daemon and its tools (no desktop clients), with its ready-made web interface
    cmake -S . -B build -G Ninja "${cross[@]}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/transmission \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_EXE_LINKER_FLAGS='-static' \
        -DCMAKE_FIND_LIBRARY_SUFFIXES=.a \
        -DCURL_NO_CURL_CMAKE=ON \
        -DCURL_INCLUDE_DIR=${deps}/include \
        -DCURL_LIBRARY=${deps}/lib/libcurl.a \
        -DCMAKE_C_STANDARD_LIBRARIES="${libraries}" \
        -DCMAKE_CXX_STANDARD_LIBRARIES="${libraries}" \
        -DENABLE_DAEMON=ON \
        -DENABLE_GTK=OFF \
        -DENABLE_QT=OFF \
        -DENABLE_MAC=OFF \
        -DENABLE_CLI=OFF \
        -DENABLE_UTILS=ON \
        -DENABLE_TESTS=OFF \
        -DENABLE_NLS=OFF \
        -DINSTALL_DOC=OFF \
        -DINSTALL_WEB=ON \
        -DREBUILD_WEB=OFF \
        -DWITH_CRYPTO=openssl \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DWITH_SYSTEMD=OFF \
        -DUSE_SYSTEM_EVENT2=OFF \
        -DUSE_SYSTEM_PSL=OFF \
        -DUSE_SYSTEM_DEFLATE=OFF \
        -DUSE_SYSTEM_DHT=OFF \
        -DUSE_SYSTEM_MINIUPNPC=OFF \
        -DUSE_SYSTEM_NATPMP=OFF \
        -DUSE_SYSTEM_UTP=OFF \
        -DUSE_SYSTEM_B64=OFF
    cmake --build build
    DESTDIR=${BUILD_PATH}/${arch}/install cmake --install build
}

# Builds the run-as helper for an architecture into ${BUILD_PATH}/<arch>/tr_runas.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    local cc='gcc'

    [ "$1" = armhf ] && cc=${TOOLS_PATH}/arm-cc
    cd ${BUILD_PATH}/$1
    cat > tr_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: tr_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("tr_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("tr_runas: could not run the program");
	return 127;
}
C
    ${cc} -O2 -static -o tr_runas tr_runas.c
}

# Checks an architecture's output folder: every program static (the ARM ones laid out for large memory pages), the
# daemon the version being packaged - started, answering transmission-remote with its session.
#
# $1 arch   The architecture (amd64 or armhf)
# $2 output The output folder
function check() {
    local arch="$1"
    local output="$2"
    local emulator='' port=19091
    local program usage pid i

    for program in ${output}/bin/*; do
        if ! file ${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${program})"

            exit 1
        fi
    done

    if [ "${arch}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${output}/bin
        emulator='qemu-arm -cpu cortex-a9'
        port=19092
    fi

    ${emulator} ${output}/bin/transmission-daemon --version > ${BUILD_PATH}/version.txt 2>&1
    grep "${VERSION}" ${BUILD_PATH}/version.txt > /dev/null
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(${emulator} ${output}/bin/tr_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: tr_runas' > /dev/null

    # (started directly, in the foreground mode, so that it's the process stopped afterwards; its web interface from
    # the output folder, as on the NAS)
    rm -rf /tmp/tr-test
    mkdir -p /tmp/tr-test/downloads
    TRANSMISSION_WEB_HOME=${output}/share/transmission/public_html ${emulator} ${output}/bin/transmission-daemon \
        --foreground --config-dir /tmp/tr-test --port ${port} --rpc-bind-address 127.0.0.1 --no-auth \
        --download-dir /tmp/tr-test/downloads --peerport $((port + 1000)) --no-portmap --no-dht \
        > /tmp/tr-test/daemon.log 2>&1 &
    pid=$!

    for i in $(seq 1 90); do
        ${emulator} ${output}/bin/transmission-remote 127.0.0.1:${port} --session-info > /tmp/tr-test/session.txt \
            2>/dev/null && break
        sleep 1
    done

    wget -q -O /tmp/tr-test/web.html http://127.0.0.1:${port}/transmission/web/ || true
    kill ${pid} 2>/dev/null || true
    wait ${pid} 2>/dev/null || true

    if ! grep "Daemon version: ${VERSION}" /tmp/tr-test/session.txt > /dev/null \
        || ! grep -i '<title>Transmission' /tmp/tr-test/web.html > /dev/null; then
        echo "Transmission (${arch}) didn't answer with its session and web interface:"
        cat /tmp/tr-test/session.txt /tmp/tr-test/daemon.log

        exit 1
    fi
}

function run() {
    local arch output program

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    download
    make_tools

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        [ "${arch}" = armhf ] && build_arm_libraries
        build_curl ${arch}
        build_transmission ${arch}
        build_runas ${arch}

        # Put together in a work folder first: the output only once it's checked (build_static.sh takes an output
        # folder that isn't empty as built)
        output=${BUILD_PATH}/${arch}/out
        mkdir -p ${output}
        cp -r ${BUILD_PATH}/${arch}/install/opt/transmission/bin ${BUILD_PATH}/${arch}/install/opt/transmission/share \
            ${output}/
        cp ${BUILD_PATH}/${arch}/tr_runas ${output}/bin/

        for program in ${output}/bin/*; do
            if [ "${arch}" = armhf ]; then
                arm-none-eabi-strip ${program}
            else
                strip ${program}
            fi
        done

        check ${arch} ${output}

        rm -rf /data/packages/static/transmission/${VERSION}/${arch}
        mkdir -p /data/packages/static/transmission/${VERSION}
        cp -r ${output} /data/packages/static/transmission/${VERSION}/${arch}
        ls -la ${output}/bin
        du -sh /data/packages/static/transmission/${VERSION}/${arch}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/transmission/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
