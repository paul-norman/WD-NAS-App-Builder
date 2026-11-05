#!/bin/bash

# Prepares Transmission (BitTorrent) for the NAS - every program fully static (musl), so nothing depends on the NAS's
# own libraries:
#  - transmission-daemon: the BitTorrent client, run in the background, with its web interface (in share/transmission)
#  - transmission-remote, -create, -edit, -show: its command-line tools
#  - tr_runas: switches to Transmission's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=4.1.4
TRANSMISSION_SHA256=86e7aa020cdf64826447034bc85f4d3b7c848d8c0891d9dc9b9fddfb2c805d22
# curl, for trackers and web seeds over HTTP(S): built small (OpenSSL and zlib only)
CURL_VERSION=8.23.0
CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
DEPS_PATH=${BUILD_PATH}/deps
OUTPUT_PATH=/data/packages/static/transmission/${VERSION}/${ARCH}

function check_static() {
    if ldd "$1" 2>&1 | grep -q '=>'; then
        echo "$1 isn't static"

        exit 1
    fi
}

function build_curl() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" curl.tar.xz ${CURL_SHA256}
    tar -xf curl.tar.xz
    cd curl-${CURL_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --with-openssl --with-zlib --without-libpsl \
        --without-libidn2 --without-nghttp2 --without-nghttp3 --without-brotli --without-zstd --without-libssh2 \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp --disable-pop3 \
        --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt --disable-docs --disable-manual
    make -j"$(nproc)"
    make install
}

function build_transmission() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/transmission/transmission/releases/download/${VERSION}/transmission-${VERSION}.tar.xz" \
        transmission.tar.xz ${TRANSMISSION_SHA256}
    tar -xf transmission.tar.xz
    cd transmission-${VERSION}

    # Only the daemon and its tools (no desktop clients), with its ready-made web interface; curl's own libraries
    # (OpenSSL, zlib) go at the end of every link (CMake's FindCURL only names libcurl itself)
    cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/transmission \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_EXE_LINKER_FLAGS='-static' \
        -DCMAKE_FIND_LIBRARY_SUFFIXES=.a \
        -DCURL_NO_CURL_CMAKE=ON \
        -DCURL_INCLUDE_DIR=${DEPS_PATH}/include \
        -DCURL_LIBRARY=${DEPS_PATH}/lib/libcurl.a \
        -DCMAKE_C_STANDARD_LIBRARIES='/usr/lib/libssl.a /usr/lib/libcrypto.a /usr/lib/libz.a' \
        -DCMAKE_CXX_STANDARD_LIBRARIES='/usr/lib/libssl.a /usr/lib/libcrypto.a /usr/lib/libz.a' \
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
    cmake --install build --strip

    for program in /opt/transmission/bin/*; do
        check_static "${program}"
    done
}

function build_runas() {
    cd ${BUILD_PATH}
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
    gcc -O2 -static -o tr_runas tr_runas.c
    strip tr_runas
    check_static tr_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_curl
    build_transmission
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -r /opt/transmission/bin /opt/transmission/share ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/tr_runas ${OUTPUT_PATH}/bin/
    ${OUTPUT_PATH}/bin/transmission-daemon --version 2>&1 | grep -q "${VERSION}"
    ls -la ${OUTPUT_PATH}/bin ${OUTPUT_PATH}/share/transmission
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
