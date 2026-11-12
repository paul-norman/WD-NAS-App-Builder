#!/bin/bash

# Builds MariaDB for the ARM models (armhf) from its source - the same version as the Intel models' (MariaDB publishes
# no 32-bit ARM release) - as fully static programs. Run by build.sh, with MariaDB's source in /work/mariadb.tar.gz:
#
#     VERSION=<MariaDB's version> bash armhf.sh
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs laid out for 4KB pages - as
# Debian's and Alpine's ARM programs and shared libraries are - crash there. A static program is laid out by its final
# link: MariaDB is cross-compiled with clang and linked by LLD (which lays programs out for 64KB pages), against Alpine's
# own static ARM libraries (OpenSSL, zlib, PCRE2, ncurses, fmt's headers - the Alpine ARM system in /armv7). Its build
# runs programs it has just built, and CMake's checks run test programs: both with QEMU's emulator. A static server
# can't load plugins from files, so the useful ones are built into it (the test and example ones are left out). The
# result has the layout of MariaDB's own release, at the path the app links to it (/usr/local/mysql): bin/ (the programs
# the Intel build keeps), scripts/ and share/.

set -e
set -o pipefail
set -x

TARGET=armv7-alpine-linux-musleabihf
SYSROOT=/armv7
PREFIX=/usr/local/mysql
SOURCE=/work/mariadb-${VERSION}
BUILD=/work/build
# The programs kept (as in the Intel build): the server, and the client tools for managing, backing up and upgrading it
PROGRAMS='mariadbd mariadb mariadb-admin mariadb-dump mariadb-import mariadb-check mariadb-show mariadb-upgrade
mariadb-tzinfo-to-sql mariadb-backup my_print_defaults resolveip'
# The plugins built into the server (each a separate file in the Intel build): storage engines, authentication, password
# checks and information schema tables. Those MariaDB only builds as separate files (MODULE_ONLY - e.g. ed25519
# authentication, server_audit, file_key_management, simple_password_check, disks) can't be: a static server can't load
# plugins from files
PLUGINS='ARCHIVE BLACKHOLE FEDERATEDX PARSEC PASSWORD_REUSE_CHECK METADATA_LOCK_INFO QUERY_CACHE_INFO
QUERY_RESPONSE_TIME LOCALES'
# The client plugins built into the client library (each a separate file in the Intel build)
CLIENT_PLUGINS='DIALOG CLIENT_ED25519 CACHING_SHA2_PASSWORD SHA256_PASSWORD MYSQL_CLEAR_PASSWORD PARSEC'

# Configures and compiles MariaDB for ARM: everything static, no Galera, no plugins needing libraries the Intel build's
# MariaDB doesn't have (RocksDB, Mroonga, Spider, CONNECT, S3, PAM, GSSAPI, HashiCorp...), no systemd (the NAS doesn't
# run it), no tests.
function build() {
    local plugins='' name

    rm -rf ${SOURCE} ${BUILD} ${PREFIX}
    tar -xzf /work/mariadb.tar.gz -C /work
    mkdir -p ${BUILD}

    # MariaDB's own fix-up for static builds gives a cache variable no type, which CMake refuses ("FORCE specified
    # without CACHE"): BOOL, as meant - stopping if the line isn't as expected
    grep -F 'SET(HAVE_DLOPEN FALSE CACHE "Disable dlopen due to -static flag" FORCE)' ${SOURCE}/configure.cmake \
        > /dev/null
    sed -i 's/SET(HAVE_DLOPEN FALSE CACHE "Disable dlopen/SET(HAVE_DLOPEN FALSE CACHE BOOL "Disable dlopen/' \
        ${SOURCE}/configure.cmake
    # ...and, without dlopen, a stand-in Dl_info of its own (its second, in my_global.h), which musl's dlfcn.h already
    # has: left out
    [ "$(grep -c 'typedef struct { const char \*dli_fname, dli_fbase; } Dl_info;' ${SOURCE}/include/my_global.h)" = 2 ]
    awk '/typedef struct \{ const char \*dli_fname, dli_fbase; \} Dl_info;/ && ++seen == 2 { next } { print }' \
        ${SOURCE}/include/my_global.h > ${SOURCE}/include/my_global.h.new
    mv ${SOURCE}/include/my_global.h.new ${SOURCE}/include/my_global.h
    # ...and, with clang, its cycle timer uses __builtin_readcyclecounter() but on 64-bit ARM and RISC-V: on 32-bit ARM
    # that reads the processor's cycle counter, which the kernel doesn't let programs do ("Illegal instruction"). Left
    # out on 32-bit ARM too, as it is when built with GCC (no cycle timer: MariaDB uses its others)
    grep -F '# if __has_builtin(__builtin_readcyclecounter) && !defined (__aarch64__)' ${SOURCE}/include/my_rdtsc.h \
        > /dev/null
    sed -i 's/# if __has_builtin(__builtin_readcyclecounter) && !defined (__aarch64__)/# if __has_builtin(__builtin_readcyclecounter) \&\& !defined (__aarch64__) \&\& !defined (__arm__)/' \
        ${SOURCE}/include/my_rdtsc.h
    grep -F '!defined (__aarch64__) && !defined (__arm__)' ${SOURCE}/include/my_rdtsc.h > /dev/null

    for name in ${PLUGINS}; do
        plugins="${plugins} -DPLUGIN_${name}=STATIC"
    done

    for name in ${CLIENT_PLUGINS}; do
        plugins="${plugins} -DCLIENT_PLUGIN_${name}=STATIC"
    done

    {
        echo 'set(CMAKE_SYSTEM_NAME Linux)'
        echo 'set(CMAKE_SYSTEM_PROCESSOR arm)'
        echo "set(CMAKE_C_COMPILER clang)"
        echo "set(CMAKE_CXX_COMPILER clang++)"
        echo "set(CMAKE_C_COMPILER_TARGET ${TARGET})"
        echo "set(CMAKE_CXX_COMPILER_TARGET ${TARGET})"
        echo "set(CMAKE_SYSROOT ${SYSROOT})"
        # (LLD for every link - with only the linker flags, modules' links would find the Alpine ARM system's own ld,
        # an ARM program)
        echo 'set(CMAKE_C_FLAGS_INIT "-mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments")'
        echo 'set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments")'
        echo 'set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")'
        echo "set(CMAKE_FIND_ROOT_PATH ${SYSROOT})"
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)'
        echo 'set(CMAKE_FIND_LIBRARY_SUFFIXES .a)'
        echo 'set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/qemu-arm;-cpu;cortex-a9)'
    } > /work/toolchain.cmake

    cd ${BUILD}
    # shellcheck disable=SC2086
    cmake ${SOURCE} -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} -DINSTALL_LAYOUT=STANDALONE \
        -DWITH_SSL=system -DWITH_ZLIB=system -DWITH_PCRE=system -DWITH_LIBFMT=system \
        -DWITH_SYSTEMD=no -DWITH_WSREP=OFF -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_MARIABACKUP=ON \
        -DWITHOUT_DYNAMIC_PLUGINS=ON -DDISABLE_SHARED=ON \
        -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO -DPLUGIN_S3=NO \
        -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_AUTH_PAM=NO -DPLUGIN_AUTH_PAM_V1=NO \
        -DPLUGIN_AUTH_GSSAPI=NO -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO -DPLUGIN_TOKUDB=NO \
        -DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZMA=NO -DPLUGIN_PROVIDER_LZO=NO \
        -DPLUGIN_PROVIDER_SNAPPY=NO ${plugins}
    make -j "$(nproc)"
    make install
}

# Keeps only the programs the Intel build keeps, stripped, and the files MariaDB's scripts and server use: no test
# suite, include files, libraries, man pages or sample configurations. Stops if a program wasn't built, or isn't static.
function trim() {
    local program name keep

    for program in ${PREFIX}/bin/*; do
        keep=''

        for name in ${PROGRAMS}; do
            [ "$(basename "${program}")" = "${name}" ] && keep=yes
        done

        if [ -z "${keep}" ] || [ ! -f "${program}" ] || ! file "${program}" | grep ELF > /dev/null; then
            rm -f "${program}"
        fi
    done

    for name in ${PROGRAMS}; do
        if [ ! -f ${PREFIX}/bin/${name} ]; then
            echo "Not built: ${name}"

            exit 1
        fi

        if ! file ${PREFIX}/bin/${name} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "Not static: ${name} ($(file ${PREFIX}/bin/${name}))"

            exit 1
        fi
    done

    rm -rf ${PREFIX}/mariadb-test ${PREFIX}/mysql-test ${PREFIX}/sql-bench ${PREFIX}/include ${PREFIX}/man \
        ${PREFIX}/docs ${PREFIX}/support-files ${PREFIX}/lib
    # (where WD's start command points the server for plugins: built in, so it stays empty)
    mkdir -p ${PREFIX}/lib/plugin
    llvm-strip ${PREFIX}/bin/*
}

build
trim
