#!/bin/bash

# Builds the shared libraries that Jellyfin's portable release needs, but which are built for a newer glibc than the
# NAS's (Debian Bullseye, glibc 2.31) or are too old on the NAS - all built here on Bullseye:
#  - libe_sqlite3.so - Jellyfin's database engine (its bundled copy needs glibc 2.34). Same SQLite version and build
#                      options as the copy bundled with Jellyfin (see "PRAGMA compile_options")
#  - libva.so.2, libva-drm.so.2, libdrm.so.2 - newer than the NAS's (libva 2.10, libdrm 2.4.104), which
#                      jellyfin-ffmpeg's portable build needs for VA-API hardware transcoding. libva uses the NAS's own
#                      Intel i965 driver from /usr/lib/x86_64-linux-gnu/dri
#  - vainfo - lists what the GPU can decode and encode, so that the app can pick Jellyfin's transcoding settings

set -e
set -o pipefail
set -x

# The Jellyfin version these libraries are for (its bundled SQLite version decides SQLITE_VERSION)
VERSION=12.4
SQLITE_VERSION=3530300
SQLITE_YEAR=2026
LIBVA_VERSION=2.24.1
LIBVA_UTILS_VERSION=2.24.0
LIBDRM_VERSION=2.4.134

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
PREFIX=${BUILD_PATH}/prefix
OUTPUT_PATH=/data/packages/static/jellyfin/${VERSION}/${ARCH}

function build_sqlite() {
    cd ${BUILD_PATH}

    # Download
    wget -q "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip"
    unzip -q "sqlite-amalgamation-${SQLITE_VERSION}.zip"
    cd "sqlite-amalgamation-${SQLITE_VERSION}"

    # Like Jellyfin's copy, provide the (unused) encryption functions as stubs, so that bindings expecting them work
    cat > key_stubs.c <<'EOF'
#include "sqlite3.h"
int sqlite3_key(sqlite3 *db, const void *key, int len) { return SQLITE_ERROR; }
int sqlite3_key_v2(sqlite3 *db, const char *name, const void *key, int len) { return SQLITE_ERROR; }
int sqlite3_rekey(sqlite3 *db, const void *key, int len) { return SQLITE_ERROR; }
int sqlite3_rekey_v2(sqlite3 *db, const char *name, const void *key, int len) { return SQLITE_ERROR; }
EOF

    # Build (the options match those of Jellyfin's bundled libe_sqlite3.so)
    gcc -O2 -fPIC -shared -o libe_sqlite3.so sqlite3.c key_stubs.c -Wl,-soname,libe_sqlite3.so \
        -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
        -DSQLITE_DQS=0 \
        -DSQLITE_ENABLE_COLUMN_METADATA \
        -DSQLITE_ENABLE_FTS3 \
        -DSQLITE_ENABLE_FTS3_PARENTHESIS \
        -DSQLITE_ENABLE_FTS4 \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_GEOPOLY \
        -DSQLITE_ENABLE_MATH_FUNCTIONS \
        -DSQLITE_ENABLE_PREUPDATE_HOOK \
        -DSQLITE_ENABLE_RTREE \
        -DSQLITE_ENABLE_SESSION \
        -DSQLITE_ENABLE_SNAPSHOT \
        -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
        -lpthread -lm -ldl
    strip libe_sqlite3.so
}

function build_libdrm() {
    cd ${BUILD_PATH}

    # Download
    wget -q "https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM_VERSION}.tar.xz"
    tar -xf "libdrm-${LIBDRM_VERSION}.tar.xz"
    cd "libdrm-${LIBDRM_VERSION}"

    # Only the core library (the NAS's i965 driver uses its own libdrm_intel)
    meson setup build --prefix=${PREFIX} --libdir=lib --buildtype=release \
        -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
        -Dtests=false -Dman-pages=disabled -Dvalgrind=disabled -Dcairo-tests=disabled
    ninja -C build install
}

function build_libva() {
    cd ${BUILD_PATH}

    # Download
    wget -q "https://github.com/intel/libva/archive/refs/tags/${LIBVA_VERSION}.tar.gz" -O libva.tar.gz
    tar -xf libva.tar.gz
    cd "libva-${LIBVA_VERSION}"

    # DRM only (no X11 / Wayland), looking for drivers where the NAS keeps them
    PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig meson setup build --prefix=${PREFIX} --libdir=lib --buildtype=release \
        -Ddriverdir=/usr/lib/x86_64-linux-gnu/dri -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Denable_docs=false
    ninja -C build install
}

function build_libva_utils() {
    cd ${BUILD_PATH}

    # Download
    wget -q "https://github.com/intel/libva-utils/archive/refs/tags/${LIBVA_UTILS_VERSION}.tar.gz" -O libva-utils.tar.gz
    tar -xf libva-utils.tar.gz
    cd "libva-utils-${LIBVA_UTILS_VERSION}"

    # Only vainfo is used, over DRM (no X11 / Wayland)
    PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig meson setup build --prefix=${PREFIX} --buildtype=release \
        -Ddrm=true -Dx11=false -Dwayland=false -Dtests=false
    ninja -C build vainfo/vainfo
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_sqlite
    build_libdrm
    build_libva
    build_libva_utils

    # Copy to output (the real files, under the names they are loaded by)
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/sqlite-amalgamation-${SQLITE_VERSION}/libe_sqlite3.so ${OUTPUT_PATH}/
    cp -L ${PREFIX}/lib/libdrm.so.2 ${PREFIX}/lib/libva.so.2 ${PREFIX}/lib/libva-drm.so.2 ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/libva-utils-${LIBVA_UTILS_VERSION}/build/vainfo/vainfo ${OUTPUT_PATH}/
    strip ${OUTPUT_PATH}/libdrm.so.2 ${OUTPUT_PATH}/libva.so.2 ${OUTPUT_PATH}/libva-drm.so.2 ${OUTPUT_PATH}/vainfo

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
