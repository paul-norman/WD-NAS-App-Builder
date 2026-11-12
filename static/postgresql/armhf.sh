#!/bin/bash

# Builds PostgreSQL for the ARM models (armhf) - the same versions as the Intel models' build, with the same extensions:
# PostgreSQL's own (contrib), PostGIS (no rasters) with GEOS and PROJ, pgvector, pg_cron, pg_partman and pgaudit. Run by
# build.sh inside the Debian stage of the Dockerfile (with chroot), with the sources in /work (postgresql.tar.bz2,
# geos.tar.bz2, proj.tar.gz, postgis.tar.gz, pgvector.tar.gz, pg_cron.tar.gz, pg_partman.tar.gz, pgaudit.tar.gz):
#
#     VERSION=<PostgreSQL's version> bash /work/armhf.sh
#
# Everything is compiled with Debian's cross-compiler, against Debian's own builds of the libraries (OpenSSL, ICU, LZ4,
# Zstandard, zlib, readline, libuuid, libxml2, json-c, protobuf-c, GMP, SQLite). PostGIS and the extensions ask
# PostgreSQL's pg_config (an ARM program) how it was built, so it's run with QEMU's emulator; CMake's checks too. The
# libraries and Debian's glibc are bundled in lib/ (the NAS's own are too old), and every program uses the bundled
# glibc's loader by its full path - the app's folder on the NAS (so it's prepared there, and the app must be on the
# NAS's first volume, where the NAS installs apps). Leaves:
#  - ${FINAL}: bin/ (with pg_runas), lib/, share/ - the Intel build's layout
#  - /work/sources: the sources of the bundled libraries under a license that asks for them (Debian's source packages)

set -e
set -o pipefail
set -x

HOST=arm-linux-gnueabihf
# Where it's built (a prefix containing "pgsql", as the Intel build's: share/ and lib/ without a postgresql folder)
PREFIX=/usr/local/pgsql
# Where it lives on the NAS (the app's folder), for the programs to find the loader
FINAL=/mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql
LOADER=ld-linux-armhf.so.3
# Where Debian keeps the ARM libraries (multiarch)
LIB_PATHS="${PREFIX}/lib /lib/${HOST} /usr/lib/${HOST}"
EMULATOR='/usr/bin/qemu-arm-static -cpu cortex-a9'
export PKG_CONFIG_LIBDIR=/usr/lib/${HOST}/pkgconfig:/usr/share/pkgconfig

# Unpacks a source archive from /work into a folder of /work: $1 = the archive's name, $2 = the folder.
function unpack() {
    rm -rf /work/$2
    mkdir -p /work/$2
    tar -xf /work/$1 -C /work/$2 --strip-components=1
}

# Debian's multiarch cross-compiling for CMake: its ARM libraries are found in /usr/lib/arm-linux-gnueabihf, and the
# programs CMake's checks build run with QEMU.
function toolchain() {
    cat > /work/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER ${HOST}-gcc)
set(CMAKE_CXX_COMPILER ${HOST}-g++)
set(CMAKE_LIBRARY_ARCHITECTURE ${HOST})
set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/qemu-arm-static;-cpu;cortex-a9)
EOF
}

function build_postgresql() {
    rm -rf ${PREFIX}
    unpack postgresql.tar.bz2 postgresql
    cd /work/postgresql
    # Its configure finds some linker options by running a test program, which it can't when cross-compiling, and then
    # assumes they don't work: given here, as on Linux they do. Without --export-dynamic, the server's functions aren't
    # visible to its modules ("undefined symbol: CurrentMemoryContext")
    ./configure --build=x86_64-linux-gnu --host=${HOST} --prefix=${PREFIX} --with-openssl --with-icu --with-lz4 \
        --with-zstd --with-uuid=e2fs --with-readline \
        pgac_cv_prog_cc_LDFLAGS_EX_BE__Wl___export_dynamic=yes pgac_cv_prog_cc_LDFLAGS__Wl___as_needed=yes

    # (any other check a later version assumes the answer to, for lack of running it, is found here)
    if grep 'result: assuming' config.log; then
        echo "PostgreSQL's configure assumed the answers above: give them (see above)"

        exit 1
    fi

    make -j "$(nproc)"
    make install
    # The usual extensions (pgcrypto, uuid-ossp, pg_trgm, hstore, citext...)
    make -C contrib -j "$(nproc)"
    make -C contrib install

    # pg_config, for PostGIS and the extensions: the ARM program, with QEMU
    printf '#!/bin/sh\nexec %s %s/bin/pg_config "$@"\n' "${EMULATOR}" ${PREFIX} > /work/pg_config
    chmod 755 /work/pg_config
}

# PostGIS's libraries: GEOS (geometry operations) and PROJ (coordinate systems, with its database of them - no network
# grids or TIFF)
function build_geos_proj() {
    unpack geos.tar.bz2 geos
    cmake -S /work/geos -B /work/geos/build -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF
    cmake --build /work/geos/build -j "$(nproc)" --target install

    unpack proj.tar.gz proj
    cmake -S /work/proj -B /work/proj/build -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF -DBUILD_APPS=OFF \
        -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DEXE_SQLITE3=/usr/bin/sqlite3
    cmake --build /work/proj/build -j "$(nproc)" --target install
}

# A compiler for PostGIS's configure, which runs test programs to read PROJ's and protobuf-c's versions (with no way to
# give them otherwise): the ARM compiler, turning the test program it links (conftest) into a script running it with
# QEMU (with PostgreSQL's own libraries found). configure then finds that it can run what it builds - it's given --host
# without --build, so it tries rather than assuming it can't.
function make_run_cc() {
    {
        echo '#!/bin/sh'
        echo "out=''"
        echo "previous=''"
        echo 'for arg in "$@"; do'
        echo '    [ "${previous}" = -o ] && out="${arg}"'
        echo '    previous="${arg}"'
        echo 'done'
        echo "${HOST}-gcc \"\$@\" || exit \$?"
        echo 'case "${out}" in'
        echo '    conftest|*/conftest)'
        echo '        mv "${out}" "${out}.arm"'
        echo "        printf '#!/bin/sh\\nexec ${EMULATOR} -E LD_LIBRARY_PATH=${PREFIX}/lib %s \"\$@\"\\n' \"\$(cd \"\$(dirname \"\${out}\")\" && pwd)/\$(basename \"\${out}\").arm\" > \"\${out}\""
        echo '        chmod 755 "${out}"'
        echo '        ;;'
        echo 'esac'
    } > /work/run-cc
    chmod 755 /work/run-cc
}

# The extensions, built against this PostgreSQL (its pg_config) and installed into it
function build_extensions() {
    make_run_cc
    unpack postgis.tar.gz postgis
    cd /work/postgis
    # (CPPBIN: its SQL files are preprocessed with cpp, and the Debian stage only has the ARM compiler's)
    CC=/work/run-cc CPPBIN=/usr/bin/${HOST}-cpp LDFLAGS="-L${PREFIX}/lib" CPPFLAGS="-I${PREFIX}/include" \
        ./configure --host=${HOST} \
        --with-pgconfig=/work/pg_config --with-geosconfig=${PREFIX}/bin/geos-config --with-projdir=${PREFIX} \
        --without-raster --with-protobuf
    make -j "$(nproc)"
    make install

    # Pgvector builds for the build machine's CPU by default - OPTFLAGS="" keeps it to plain ARMv7
    unpack pgvector.tar.gz pgvector
    make -C /work/pgvector OPTFLAGS='' PG_CONFIG=/work/pg_config -j "$(nproc)" install

    unpack pg_cron.tar.gz pg_cron
    make -C /work/pg_cron PG_CONFIG=/work/pg_config -j "$(nproc)" install

    unpack pg_partman.tar.gz pg_partman
    make -C /work/pg_partman PG_CONFIG=/work/pg_config -j "$(nproc)" install

    unpack pgaudit.tar.gz pgaudit
    make -C /work/pgaudit USE_PGXS=1 PG_CONFIG=/work/pg_config -j "$(nproc)" install
}

# The helper running PostgreSQL's programs as the postgres user (as the Intel build's: PostgreSQL refuses to run as
# root, and the NAS has no su). Fully static
function build_runas() {
    cat > /work/pg_runas.c <<'C'
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
    ${HOST}-gcc -O2 -static -o /work/pg_runas /work/pg_runas.c
    ${HOST}-strip /work/pg_runas
}

# Finds an ARM library by name: PostgreSQL's own (libpq, GEOS, PROJ...), else where Debian keeps them.
#
# $1 name The library's file name (e.g. libssl.so.3)
#
# Prints its path (none if it isn't there)
function find_library() {
    local folder

    for folder in ${LIB_PATHS}; do
        if [ -e "${folder}/$1" ]; then
            echo "${folder}/$1"

            return 0
        fi
    done
}

# The libraries a program or library needs, by name (its ELF's NEEDED entries).
#
# $1 file The program or library
#
# Prints one name a line
function needed() {
    ${HOST}-readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
}

# Whether a file is an ARM program or library (not a script or link).
#
# $1 file The file
function is_elf() {
    [ -f "$1" ] && [ ! -L "$1" ] && file "$1" | grep ELF > /dev/null
}

# Copies the build to the app's path with the Intel build's layout, and every library its programs, libraries and
# extensions need (and the ones those need in turn) into its lib/, with glibc's loader. Stops if one isn't found. (A
# queue in an array read from a file: with pipefail, a pipe into head can fail at random, and the chroot has no
# /dev/fd for <(...))
function bundle() {
    local queue name path file

    rm -rf ${FINAL}
    mkdir -p ${FINAL}
    cp -a ${PREFIX}/bin ${PREFIX}/lib ${PREFIX}/share ${FINAL}/
    rm -rf ${FINAL}/lib/pkgconfig ${FINAL}/lib/cmake ${FINAL}/bin/geos-config ${FINAL}/lib/*.a ${FINAL}/lib/pgxs
    cp /work/pg_runas ${FINAL}/bin/
    : > /work/needed

    for file in ${FINAL}/bin/* ${FINAL}/lib/*.so*; do
        is_elf "${file}" || continue
        ${HOST}-strip --strip-unneeded "${file}"
        needed "${file}" >> /work/needed
    done

    mapfile -t queue < /work/needed

    while [ ${#queue[@]} -gt 0 ]; do
        name="${queue[0]}"
        queue=("${queue[@]:1}")

        if [ -z "${name}" ] || [ -e "${FINAL}/lib/${name}" ]; then
            continue
        fi

        path="$(find_library "${name}")"

        if [ -z "${path}" ]; then
            echo "Library not found: ${name}"

            exit 1
        fi

        cp -L "${path}" "${FINAL}/lib/${name}"
        needed "${FINAL}/lib/${name}" > /work/needed
        mapfile -t -O ${#queue[@]} queue < /work/needed
    done

    cp -L "$(find_library ${LOADER})" ${FINAL}/lib/${LOADER}
}

# Points the programs at the bundled loader (by its full path) and at the libraries next to them, and each library at
# the others ($ORIGIN) - so that none of the NAS's own libraries is used. pg_runas is static. The NAS's ARM kernels use
# 64KB memory pages, so patchelf aligns what it adds to those.
function patch() {
    local file

    for file in ${FINAL}/lib/*.so*; do
        is_elf "${file}" || continue
        [ "$(basename "${file}")" = ${LOADER} ] && continue
        patchelf --page-size 65536 --set-rpath '$ORIGIN' "${file}"
    done

    for file in ${FINAL}/bin/*; do
        is_elf "${file}" || continue
        [ "$(basename "${file}")" = pg_runas ] && continue
        patchelf --page-size 65536 --set-interpreter ${FINAL}/lib/${LOADER} --set-rpath '$ORIGIN/../lib' "${file}"
    done

    chmod 755 ${FINAL}/lib/${LOADER}
}

# Downloads the Debian source packages of the bundled libraries whose license asks for their source (GPL, LGPL, MPL - by
# their copyright files, which takes in some it needn't, rather than miss one) into /work/sources, and lists every
# bundled Debian library's package in /work/sources/packages.tsv. GCC's runtime libraries are left out, as their
# license exempts what's built with them. (PostgreSQL's own libraries, GEOS and PROJ are from their own sources.)
function sources() {
    local lib package source version license

    rm -rf /work/sources
    mkdir -p /work/sources
    printf 'library\tpackage\tsource\tversion\tlicense\n' > /work/sources/packages.tsv
    apt-get update

    for lib in ${FINAL}/lib/*.so*; do
        is_elf "${lib}" || continue
        [ -e "${PREFIX}/lib/$(basename "${lib}")" ] && continue
        package="$(dpkg -S "*/$(basename "${lib}")" 2>/dev/null \
            | awk -F ': ' '/:armhf: / && !found++ { print $1 }' || true)"

        if [ -z "${package}" ]; then
            echo "No package found for: ${lib}"

            exit 1
        fi

        source="$(dpkg-query -W -f '${source:Package}' "${package}")"
        version="$(dpkg-query -W -f '${source:Version}' "${package}")"
        license='other'

        if grep -qE 'GPL|MPL|Mozilla Public' "/usr/share/doc/${package%%:*}/copyright" 2>/dev/null; then
            license='copyleft'
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "${lib}")" "${package}" "${source}" "${version}" "${license}" \
            >> /work/sources/packages.tsv

        if [ "${license}" = copyleft ] && [[ ! "${source}" =~ ^gcc(-[0-9]+)?$ ]] \
            && [ ! -e "/work/sources/${source}_${version#*:}.dsc" ]; then
            (cd /work/sources && apt-get source --download-only "${source}=${version}")
        fi
    done

    rm -rf /var/lib/apt/lists/*
}

toolchain
build_postgresql
build_geos_proj
build_extensions
build_runas
bundle
patch
sources
