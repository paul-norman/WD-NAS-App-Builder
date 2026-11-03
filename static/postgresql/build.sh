#!/bin/bash

# PostgreSQL for the NAS, built on Debian Bullseye (the NAS's own Debian version), with OpenSSL 3.5 LTS built from
# source and the other libraries it uses (ICU, LZ4, Zstandard, zlib, readline, libuuid) bundled next to it - the NAS's
# system is stripped down, so it isn't relied on for anything beyond glibc and libstdc++. Every program and library
# finds the bundled ones through its own location ($ORIGIN), and PostgreSQL finds its files relative to its programs
# too, so the whole tree can live anywhere (the app's folder). Extensions included besides PostgreSQL's own (contrib):
# PostGIS (geometry / geography and topology - no rasters, which need GDAL), with GEOS and PROJ built from source and
# GMP bundled, pgvector, pg_cron, pg_partman and pgaudit

set -e
set -o pipefail
set -x

VERSION=18.6
SHA256=555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f
OPENSSL_VERSION=3.5.9
GEOS_VERSION=3.15.0
GEOS_SHA256=d5e5192a686d065eaed082de14dd26244c5c8e02bff16b2c6cce3265f648e00e
PROJ_VERSION=9.9.0
PROJ_SHA256=791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3
POSTGIS_VERSION=3.7.0
POSTGIS_SHA256=832bbf50f2b6f57fab053bc9676b3bfe641e5bf966cdcb28c7926f8d4b3c5e04
PGVECTOR_VERSION=0.8.7
PGVECTOR_SHA256=cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85
PG_CRON_VERSION=1.6.8
PG_CRON_SHA256=c19ab9bb35406c60fb51ecda993737c083850abe424acb6c1030439d00a1f8e4
PG_PARTMAN_VERSION=5.5.0
PG_PARTMAN_SHA256=a3f100ae871677f0012579f58542c174900297f664a4ad2be0256e7ee5e33502
PGAUDIT_VERSION=18.0
PGAUDIT_SHA256=988e8afeda320ebe0a3e632ef6b6bce5d3a08346c2e100a173a585c9521d1fa5
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
# A prefix containing "pgsql", so that PostgreSQL's share and lib folders are share/ and lib/
PREFIX=/usr/local/pgsql
OUTPUT_PATH=/data/packages/static/postgresql/${VERSION}/${ARCH}

# The NAS's own libraries (everything else a program needs is bundled)
SYSTEM_LIBS='libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libstdc++.so.6 libgcc_s.so.1 ld-linux-x86-64.so.2'

function build_openssl() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl-${OPENSSL_VERSION}.tar.gz "${OPENSSL_SHA256}"
    tar -xzf openssl-${OPENSSL_VERSION}.tar.gz
    cd openssl-${OPENSSL_VERSION}
    ./Configure --prefix=${PREFIX} --libdir=lib shared no-tests no-docs
    make -j "$(nproc)"
    make install_sw
}

function build_postgresql() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.bz2" \
        postgresql-${VERSION}.tar.bz2 "${SHA256}"
    tar -xjf postgresql-${VERSION}.tar.bz2
    cd postgresql-${VERSION}
    ./configure --prefix=${PREFIX} --with-openssl --with-icu --with-lz4 --with-zstd --with-uuid=e2fs --with-readline \
        --with-includes=${PREFIX}/include --with-libraries=${PREFIX}/lib
    make -j "$(nproc)"
    make install
    # The usual extensions (pgcrypto, uuid-ossp, pg_trgm, hstore, citext...)
    make -C contrib -j "$(nproc)"
    make -C contrib install
}

# Downloads and unpacks a source archive after checking its checksum: $1 = URL, $2 = SHA-256, $3 = folder to unpack into
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" source.tar "$2"
    mkdir -p "$3"
    tar -xf source.tar -C "$3" --strip-components=1
    rm source.tar
}

# PostGIS's libraries: GEOS (geometry operations) and PROJ (coordinate systems, with its database of them - no network
# grids or TIFF)
function build_geos_proj() {
    fetch "https://github.com/libgeos/geos/releases/download/${GEOS_VERSION}/geos-${GEOS_VERSION}.tar.bz2" ${GEOS_SHA256} geos
    cmake -S ${BUILD_PATH}/geos -B ${BUILD_PATH}/geos/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF
    cmake --build ${BUILD_PATH}/geos/build -j "$(nproc)" --target install

    fetch "https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz" ${PROJ_SHA256} proj
    cmake -S ${BUILD_PATH}/proj -B ${BUILD_PATH}/proj/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF
    cmake --build ${BUILD_PATH}/proj/build -j "$(nproc)" --target install
}

# The extensions, built against this PostgreSQL (pg_config) and installed into it
function build_extensions() {
    export PATH="${PREFIX}/bin:${PATH}"

    fetch "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" ${POSTGIS_SHA256} postgis
    cd ${BUILD_PATH}/postgis
    LDFLAGS="-L${PREFIX}/lib" CPPFLAGS="-I${PREFIX}/include" ./configure --with-pgconfig=${PREFIX}/bin/pg_config \
        --with-geosconfig=${PREFIX}/bin/geos-config --with-projdir=${PREFIX} --without-raster --with-protobuf
    make -j "$(nproc)"
    make install

    # Pgvector builds for the build machine's CPU by default - OPTFLAGS="" keeps it to plain x86-64, for the NAS's
    fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" ${PGVECTOR_SHA256} pgvector
    make -C ${BUILD_PATH}/pgvector OPTFLAGS='' PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" ${PG_CRON_SHA256} pg_cron
    make -C ${BUILD_PATH}/pg_cron PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/pgpartman/pg_partman/archive/refs/tags/v${PG_PARTMAN_VERSION}.tar.gz" ${PG_PARTMAN_SHA256} pg_partman
    make -C ${BUILD_PATH}/pg_partman PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/pgaudit/pgaudit/archive/refs/tags/${PGAUDIT_VERSION}.tar.gz" ${PGAUDIT_SHA256} pgaudit
    make -C ${BUILD_PATH}/pgaudit USE_PGXS=1 PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install
}

# A tiny helper to run PostgreSQL's programs as the postgres user (PostgreSQL refuses to run as root, and the NAS has no
# su): drops root's groups, switches to the given IDs, checks the switch worked, then runs the program. Fully static
function build_runas() {
    cd ${BUILD_PATH}
    cat > pg_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	if (argc < 4) {
		fprintf(stderr, "Usage: pg_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (uid == 0 || setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0 || getuid() != uid || geteuid() != uid) {
		perror("pg_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("pg_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o pg_runas pg_runas.c
    strip pg_runas
}

# Copies the libraries each program needs (beyond the NAS's own) next to them, and points every program and library at
# them through its own location
function bundle() {
    mkdir -p ${OUTPUT_PATH}
    cp -r ${PREFIX}/bin ${PREFIX}/lib ${PREFIX}/share ${OUTPUT_PATH}/
    rm -rf ${OUTPUT_PATH}/lib/pkgconfig ${OUTPUT_PATH}/lib/cmake ${OUTPUT_PATH}/bin/geos-config ${OUTPUT_PATH}/lib/*.a ${OUTPUT_PATH}/lib/engines-3 ${OUTPUT_PATH}/lib/ossl-modules ${OUTPUT_PATH}/lib/pgxs

    # PostgreSQL's extensions are in lib/ too, next to the libraries
    for elf in ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/*.so*; do
        [ -L "${elf}" ] || ! file "${elf}" | grep -q ELF && continue
        ldd "${elf}" | awk '/=> \// { print $1, $3 }' | while read -r name path; do
            case " $(echo ${SYSTEM_LIBS}) " in *" ${name} "*) continue ;; esac
            [ -e "${OUTPUT_PATH}/lib/${name}" ] || cp -L "${path}" "${OUTPUT_PATH}/lib/${name}"
        done
    done
    strip --strip-unneeded ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/*.so* 2>/dev/null || true

    for elf in ${OUTPUT_PATH}/bin/*; do file "${elf}" | grep -q ELF && patchelf --set-rpath '$ORIGIN/../lib' "${elf}"; done

    for elf in ${OUTPUT_PATH}/lib/*.so*; do [ -L "${elf}" ] || patchelf --set-rpath '$ORIGIN' "${elf}"; done
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_openssl
    build_geos_proj
    build_postgresql
    build_extensions
    rm -rf ${OUTPUT_PATH}
    bundle
    build_runas
    cp ${BUILD_PATH}/pg_runas ${OUTPUT_PATH}/bin/
    du -sh ${OUTPUT_PATH}
    ${OUTPUT_PATH}/bin/postgres --version

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
