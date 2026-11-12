#!/bin/bash

# Builds PostgreSQL for the ARM models (armhf) - the same versions as the Intel models' build, with the same extensions:
# PostgreSQL's own (contrib), PostGIS (no rasters) with GEOS and PROJ, pgvector, pg_cron, pg_partman and pgaudit. Run by
# build.sh inside the Alpine stage of the Dockerfile (with chroot), with the sources in /work (postgresql.tar.bz2,
# geos.tar.bz2, proj.tar.gz, postgis.tar.gz, pgvector.tar.gz, pg_cron.tar.gz, pg_partman.tar.gz, pgaudit.tar.gz,
# musl.tar.gz, util-linux.tar.xz, lz4.tar.gz, protobuf-c.tar.gz, gmp.tar.xz):
#
#     VERSION=<PostgreSQL's version> bash /work/armhf.sh
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs and libraries laid out for 4KB
# pages - as Debian's and Alpine's ARM ones are - crash there. Everything here is compiled with clang and linked by LLD,
# which lays them out for 64KB pages. PostgreSQL loads its extensions as libraries, so it can't be fully static: it uses
# musl (the C library) built here, and every other library is built into each program and library that uses it (Alpine's
# static ARM libraries, in /armv7, and libuuid, GEOS and PROJ built here) - their symbols kept inside, so that two
# extensions holding the same library don't clash. The programs use musl's loader by its full path: the app's folder on
# the NAS (so it's built there, and the app must be on the NAS's first volume, where the NAS installs apps). ICU's data
# is built in (Alpine keeps it in a file of its own). configure's test programs run with QEMU's emulator, as do
# pg_config's answers to PostGIS and the extensions. Leaves ${FINAL}: bin/ (with pg_runas), lib/, share/ - the Intel
# build's layout.

set -e
set -o pipefail
set -x

TARGET=armv7-alpine-linux-musleabihf
SYSROOT=/armv7
# Where it's built (a prefix containing "pgsql", as the Intel build's: share/ and lib/ without a postgresql folder)
PREFIX=/usr/local/pgsql
# Where it lives on the NAS (the app's folder), for the programs to find musl's loader
FINAL=/mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql
LOADER=ld-musl-armhf.so.1
# Libraries built here, into the Alpine ARM system
DEPS=/usr/local
TOOLS=/work/tools
CFLAGS_ARM='-O2 -fPIC'
# LLVM's archive tools, which work for any target (the builds otherwise look for e.g. arm-linux-musleabihf-ar)
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip
# The other projects' static libraries built into PostgreSQL's programs, libraries and extensions: their symbols are
# kept inside each (not PostgreSQL's own, e.g. libpgcommon's, which libpq hands on to its programs)
# (colon separated: -Wl, would split commas into arguments of their own)
OTHER_LIBS='libssl.a:libcrypto.a:libz.a:libzstd.a:liblz4.a:libicuuc.a:libicui18n.a:libicudata.a:libxml2.a:liblzma.a:
libjson-c.a:libprotobuf-c.a:libsqlite3.a:libgeos.a:libgeos_c.a:libproj.a:libuuid.a:libedit.a:libncursesw.a:libstdc++.a:libgmp.a'
OTHER_LIBS="${OTHER_LIBS//$'\n'/}"
# Every program and library: musl's loader and its libraries by their full path (the app's lib/), GCC's runtime built
# in, and the symbols of the other projects' static libraries built into it kept inside it - and the libraries built
# here found
LDFLAGS_ARM="-static-libgcc -Wl,--dynamic-linker=${FINAL}/lib/${LOADER} -Wl,-rpath,${FINAL}/lib
-Wl,--exclude-libs=${OTHER_LIBS} -L${SYSROOT}${DEPS}/lib"
LDFLAGS_ARM="${LDFLAGS_ARM//$'\n'/ }"
CPPFLAGS_ARM="-I${SYSROOT}${DEPS}/include"

# The cross-compiling tools: cc and c++ (clang for the ARM models, against the Alpine ARM system, linked by LLD, with
# GCC's runtime built in - the Alpine ARM system's shared one isn't there), each turning a test program it links
# (conftest) into a script running it with QEMU (with the Alpine ARM system's musl);
# pkg-config (the Alpine ARM system's libraries and those built here, with what their static libraries need); a CMake
# toolchain file; pg_config (PostgreSQL's, with QEMU).
function make_tools() {
    local compiler

    mkdir -p ${TOOLS}

    for compiler in cc:clang c++:clang++; do
        {
            echo '#!/bin/sh'
            echo "out=''"
            echo "previous=''"
            echo 'for arg in "$@"; do'
            echo '    [ "${previous}" = -o ] && out="${arg}"'
            echo '    previous="${arg}"'
            echo 'done'
            echo "${compiler#*:} --target=${TARGET} --sysroot=${SYSROOT} -mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments -static-libgcc \"\$@\" || exit \$?"
            echo 'case "${out}" in'
            echo '    conftest|*/conftest)'
            echo '        mv "${out}" "${out}.arm"'
            echo "        printf '#!/bin/sh\\nexec qemu-arm -cpu cortex-a9 -L ${SYSROOT} %s \"\$@\"\\n' \"\$(cd \"\$(dirname \"\${out}\")\" && pwd)/\$(basename \"\${out}\").arm\" > \"\${out}\""
            echo '        chmod 755 "${out}"'
            echo '        ;;'
            echo 'esac'
        } > ${TOOLS}/${compiler%%:*}
    done

    {
        echo '#!/bin/sh'
        echo "export PKG_CONFIG_SYSROOT_DIR=${SYSROOT}"
        echo "export PKG_CONFIG_LIBDIR=${SYSROOT}${DEPS}/lib/pkgconfig:${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
        echo 'exec /usr/bin/pkg-config --static "$@"'
    } > ${TOOLS}/pkg-config
    printf '#!/bin/sh\nexec qemu-arm -cpu cortex-a9 %s/bin/pg_config "$@"\n' ${PREFIX} > ${TOOLS}/pg_config
    # (xml2-config, which PostGIS asks: libxml2's pkg-config, the Alpine ARM system's)
    {
        echo '#!/bin/sh'
        echo 'case "$1" in'
        echo "    --cflags) exec ${TOOLS}/pkg-config --cflags libxml-2.0 ;;"
        echo "    --libs) exec ${TOOLS}/pkg-config --libs libxml-2.0 ;;"
        echo "    --version) exec ${TOOLS}/pkg-config --modversion libxml-2.0 ;;"
        echo 'esac'
    } > ${TOOLS}/xml2-config
    chmod 755 ${TOOLS}/cc ${TOOLS}/c++ ${TOOLS}/pkg-config ${TOOLS}/pg_config ${TOOLS}/xml2-config

    {
        echo 'set(CMAKE_SYSTEM_NAME Linux)'
        echo 'set(CMAKE_SYSTEM_PROCESSOR arm)'
        echo 'set(CMAKE_C_COMPILER clang)'
        echo 'set(CMAKE_CXX_COMPILER clang++)'
        echo "set(CMAKE_C_COMPILER_TARGET ${TARGET})"
        echo "set(CMAKE_CXX_COMPILER_TARGET ${TARGET})"
        echo "set(CMAKE_SYSROOT ${SYSROOT})"
        echo 'set(CMAKE_C_FLAGS_INIT "-mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments -static-libgcc")'
        echo 'set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments -static-libgcc")'
        echo 'set(CMAKE_POSITION_INDEPENDENT_CODE ON)'
        echo "set(CMAKE_FIND_ROOT_PATH ${SYSROOT})"
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)'
        echo "set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/qemu-arm;-cpu;cortex-a9;-L;${SYSROOT})"
        echo "set(PKG_CONFIG_EXECUTABLE ${TOOLS}/pkg-config)"
    } > /work/toolchain.cmake
}

# Unpacks a source archive from /work into a folder of /work: $1 = the archive's name, $2 = the folder.
function unpack() {
    rm -rf /work/$2
    mkdir -p /work/$2
    tar -xf /work/$1 -C /work/$2 --strip-components=1
}

# musl, the C library, built for the ARM models with LLD (Alpine's is laid out for 4KB pages): its loader, which is
# also the library itself, goes in ${FINAL}/lib - and as libc.so, the name programs ask for.
function build_musl() {
    unpack musl.tar.gz musl
    cd /work/musl
    CC=${TOOLS}/cc CFLAGS='-O2' LIBCC='-lgcc' ./configure --target=arm-linux-musleabihf --prefix=/work/musl-out \
        --syslibdir=/work/musl-out/lib --disable-static
    make -j "$(nproc)"
    make install
    rm -rf ${FINAL}
    mkdir -p ${FINAL}/lib
    cp /work/musl-out/lib/libc.so ${FINAL}/lib/${LOADER}
    ln -s ${LOADER} ${FINAL}/lib/libc.so
}

# The libraries built here, static and position-independent (for PostgreSQL's libraries and extensions), into the
# Alpine ARM system (${DEPS} in it): libuuid (uuid-ossp - Alpine's static one can't go into a library), LZ4 and
# protobuf-c (PostGIS's - Alpine's static ones hold GCC's link-time optimisation code, which LLD can't link), GMP
# (PostGIS's - Alpine has no static one), ICU's data
# (as libicudata: Alpine's static one is only a placeholder for its separate data file), GEOS and PROJ (PostGIS's).
function build_libraries() {
    local data symbol

    unpack lz4.tar.gz lz4
    make -C /work/lz4/lib -j "$(nproc)" CC=${TOOLS}/cc CFLAGS="${CFLAGS_ARM}" BUILD_SHARED=no PREFIX=${DEPS} \
        DESTDIR=${SYSROOT} install

    unpack gmp.tar.xz gmp
    cd /work/gmp
    CC=${TOOLS}/cc CFLAGS="${CFLAGS_ARM}" ./configure --host=${TARGET} --prefix=${DEPS} --enable-static \
        --disable-shared --with-pic
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    unpack protobuf-c.tar.gz protobuf-c
    cd /work/protobuf-c
    CC=${TOOLS}/cc CXX=${TOOLS}/c++ CFLAGS="${CFLAGS_ARM}" ./configure --host=${TARGET} --prefix=${DEPS} \
        --disable-protoc --enable-static --disable-shared
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    unpack util-linux.tar.xz util-linux
    cd /work/util-linux
    CC=${TOOLS}/cc CFLAGS="${CFLAGS_ARM}" ./configure --host=${TARGET} --prefix=${DEPS} --disable-all-programs \
        --enable-libuuid --enable-static --disable-shared --without-python --without-systemd --disable-nls \
        --without-tinfo --without-ncursesw
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    data="$(ls ${SYSROOT}/usr/share/icu/*/icudt*l.dat)"
    symbol="$(basename "${data}" l.dat)_dat"
    arm-none-eabi-nm ${SYSROOT}/usr/lib/libicudata.a | grep " R ${symbol}\$" > /dev/null
    {
        echo '.section .rodata'
        echo '.balign 16'
        echo ".global ${symbol}"
        echo ".type ${symbol}, %object"
        echo "${symbol}:"
        echo ".incbin \"${data}\""
        echo ".size ${symbol}, . - ${symbol}"
    } > /work/icudata.S
    ${TOOLS}/cc -c /work/icudata.S -o /work/icudata.o
    rm -f ${SYSROOT}/usr/lib/libicudata.a
    arm-none-eabi-ar rcs ${SYSROOT}/usr/lib/libicudata.a /work/icudata.o

    unpack geos.tar.bz2 geos
    cmake -S /work/geos -B /work/geos/build -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${DEPS} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
    cmake --build /work/geos/build -j "$(nproc)"
    DESTDIR=${SYSROOT} cmake --install /work/geos/build
    # geos-config, which PostGIS asks: GEOS in the Alpine ARM system, with what its static C library needs (GEOS's C++
    # library, libstdc++)
    {
        echo '#!/bin/sh'
        echo 'case "$1" in'
        echo "    --clibs|--static-clibs) echo '-L${SYSROOT}${DEPS}/lib -lgeos_c -lgeos -lstdc++ -lm' ;;"
        echo "    --cflags|--includes) echo '-I${SYSROOT}${DEPS}/include' ;;"
        echo "    --ldflags) echo '-L${SYSROOT}${DEPS}/lib' ;;"
        echo "    --prefix) echo '${SYSROOT}${DEPS}' ;;"
        echo "    *) exec ${SYSROOT}${DEPS}/bin/geos-config \"\$@\" ;;"
        echo 'esac'
    } > ${TOOLS}/geos-config
    chmod 755 ${TOOLS}/geos-config

    unpack proj.tar.gz proj
    cmake -S /work/proj -B /work/proj/build -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${DEPS} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
        -DBUILD_APPS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DEXE_SQLITE3=/usr/bin/sqlite3
    cmake --build /work/proj/build -j "$(nproc)"
    DESTDIR=${SYSROOT} cmake --install /work/proj/build
    rm -f ${SYSROOT}${DEPS}/lib/*.la
}

# PostgreSQL itself and its own extensions (contrib), with the Intel build's options - but libedit for psql's line
# editing (readline's static library needs ncurses' too; libedit is what PostgreSQL's own packages also offer).
function build_postgresql() {
    rm -rf ${PREFIX}
    unpack postgresql.tar.bz2 postgresql
    cd /work/postgresql
    # Its check that libpq never calls exit() (which would end the program using it) finds atexit() and pthread_exit()
    # in the static OpenSSL built into it: they register OpenSSL's clean-up and end a thread, never the program -
    # excluded from the check too
    grep -F "grep -v -e __cxa_atexit -e __tsan_func_exit | grep exit" src/interfaces/libpq/Makefile > /dev/null
    sed -i 's/grep -v -e __cxa_atexit -e __tsan_func_exit | grep exit/grep -v -e __cxa_atexit -e __tsan_func_exit -e " atexit" -e pthread_exit | grep exit/' \
        src/interfaces/libpq/Makefile
    CC=${TOOLS}/cc PKG_CONFIG=${TOOLS}/pkg-config CFLAGS="${CFLAGS_ARM}" CPPFLAGS="${CPPFLAGS_ARM}" \
        LDFLAGS="${LDFLAGS_ARM}" LIBS='-lstdc++' ./configure --host=${TARGET} --prefix=${PREFIX} --disable-rpath \
        --with-openssl --with-icu --with-lz4 --with-zstd --with-uuid=e2fs --with-libedit-preferred

    if grep 'result: assuming' config.log; then
        echo "PostgreSQL's configure assumed the answers above"

        exit 1
    fi

    make -j "$(nproc)"
    # (its installation compiles the time zone data with zic, an ARM program it has just built: with QEMU)
    make install ZIC="qemu-arm -cpu cortex-a9 /work/postgresql/src/timezone/zic"
    make -C contrib -j "$(nproc)"
    make -C contrib install
}

# The extensions, built against this PostgreSQL (its pg_config, with QEMU) and installed into it - with its makefiles'
# compiler and linker flags (PGXS)
function build_extensions() {
    unpack postgis.tar.gz postgis
    cd /work/postgis
    # (CPPBIN: its SQL files are preprocessed with cpp, which clang is here. GEOS through its geos-config, PROJ through
    # pkg-config - both giving what their static libraries need: PostGIS's configure sets its own LIBS)
    CC=${TOOLS}/cc CXX=${TOOLS}/c++ CPPBIN="clang -E" PKG_CONFIG=${TOOLS}/pkg-config CFLAGS="${CFLAGS_ARM}" \
        CPPFLAGS="${CPPFLAGS_ARM}" LDFLAGS="${LDFLAGS_ARM}" \
        ./configure --host=${TARGET} --with-pgconfig=${TOOLS}/pg_config --with-geosconfig=${TOOLS}/geos-config \
        --with-xml2config=${TOOLS}/xml2-config --without-raster --with-protobuf
    make -j "$(nproc)"
    make install

    # Pgvector builds for the build machine's CPU by default - OPTFLAGS="" keeps it to plain ARMv7
    unpack pgvector.tar.gz pgvector
    make -C /work/pgvector OPTFLAGS='' PG_CONFIG=${TOOLS}/pg_config -j "$(nproc)" install

    unpack pg_cron.tar.gz pg_cron
    make -C /work/pg_cron PG_CONFIG=${TOOLS}/pg_config -j "$(nproc)" install

    unpack pg_partman.tar.gz pg_partman
    make -C /work/pg_partman PG_CONFIG=${TOOLS}/pg_config -j "$(nproc)" install

    unpack pgaudit.tar.gz pgaudit
    make -C /work/pgaudit USE_PGXS=1 PG_CONFIG=${TOOLS}/pg_config -j "$(nproc)" install
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
    ${TOOLS}/cc -O2 -static -o /work/pg_runas /work/pg_runas.c
    llvm-strip /work/pg_runas
}

# Puts the build at the app's path with the Intel build's layout (musl's loader already there), stripped.
function assemble() {
    local file

    cp -a ${PREFIX}/bin ${PREFIX}/share ${FINAL}/
    cp -a ${PREFIX}/lib/. ${FINAL}/lib/
    rm -rf ${FINAL}/lib/pkgconfig ${FINAL}/lib/pgxs ${FINAL}/lib/*.a
    cp /work/pg_runas ${FINAL}/bin/

    for file in ${FINAL}/bin/* ${FINAL}/lib/*.so*; do
        [ -f "${file}" ] && [ ! -L "${file}" ] && file "${file}" | grep ELF > /dev/null || continue
        [ "$(basename "${file}")" = ${LOADER} ] && continue
        llvm-strip --strip-unneeded "${file}"
    done
}

make_tools
build_musl
build_libraries
build_postgresql
build_extensions
build_runas
assemble
