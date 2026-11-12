#!/bin/bash

# Builds MariaDB for the ARM models (armhf) from its source - the same version as the Intel models' (MariaDB publishes
# no 32-bit ARM release). Run by build.sh inside the Debian stage of the Dockerfile (with chroot), with MariaDB's source
# in /work/mariadb.tar.gz:
#
#     VERSION=<MariaDB's version> bash /work/armhf.sh
#
# MariaDB is compiled with Debian's cross-compiler, against Debian's own builds of its libraries (OpenSSL, zlib, PCRE2,
# ncurses, fmt's headers - so nothing is downloaded during the build). Its build runs programs it has just built (to
# generate some of its sources), and CMake's checks run test programs: both with QEMU's emulator. The result has
# the same layout as MariaDB's own release, at the path the app links to it (/usr/local/mysql), with Debian's libraries
# and glibc bundled in lib/runtime (the NAS's own are too old): its programs use them by their full path. Leaves:
#  - /usr/local/mysql: bin/ (the programs the Intel build keeps), scripts/, share/, lib/plugin/ and lib/runtime/
#  - /work/sources: the sources of the bundled libraries under a license that asks for them (Debian's source packages)

set -e
set -o pipefail
set -x

HOST=arm-linux-gnueabihf
PREFIX=/usr/local/mysql
RUNTIME=${PREFIX}/lib/runtime
LOADER=ld-linux-armhf.so.3
# Where Debian keeps the ARM libraries (multiarch)
LIB_PATHS="/lib/${HOST} /usr/lib/${HOST}"
SOURCE=/work/mariadb-${VERSION}
BUILD=/work/build
# The programs kept (as in the Intel build): the server, and the client tools for managing, backing up and upgrading it
PROGRAMS='mariadbd mariadb mariadb-admin mariadb-dump mariadb-import mariadb-check mariadb-show mariadb-upgrade
mariadb-tzinfo-to-sql mariadb-backup my_print_defaults resolveip'

# Configures and compiles MariaDB for ARM: no Galera, no plugins needing libraries the NAS's MariaDB wouldn't have
# (RocksDB, Mroonga, Spider, CONNECT, S3, PAM, GSSAPI, HashiCorp...), no systemd (the NAS doesn't run it: no stand-in
# libsystemd needed), no tests.
function build() {
    rm -rf ${SOURCE} ${BUILD} ${PREFIX}
    tar -xzf /work/mariadb.tar.gz -C /work
    mkdir -p ${BUILD}

    # Debian's multiarch cross-compiling: its ARM libraries are found in /usr/lib/arm-linux-gnueabihf
    cat > /work/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER ${HOST}-gcc)
set(CMAKE_CXX_COMPILER ${HOST}-g++)
set(CMAKE_LIBRARY_ARCHITECTURE ${HOST})
set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/qemu-arm-static;-cpu;cortex-a9)
set(PKG_CONFIG_EXECUTABLE /usr/bin/${HOST}-pkg-config)
EOF

    cd ${BUILD}
    cmake ${SOURCE} -DCMAKE_TOOLCHAIN_FILE=/work/toolchain.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} -DINSTALL_LAYOUT=STANDALONE \
        -DWITH_SSL=system -DWITH_ZLIB=system -DWITH_PCRE=system -DWITH_LIBFMT=system \
        -DWITH_SYSTEMD=no -DWITH_WSREP=OFF -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_MARIABACKUP=ON \
        -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO -DPLUGIN_S3=NO \
        -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_AUTH_PAM=NO -DPLUGIN_AUTH_PAM_V1=NO \
        -DPLUGIN_AUTH_GSSAPI=NO -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO -DPLUGIN_TOKUDB=NO \
        -DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZMA=NO -DPLUGIN_PROVIDER_LZO=NO \
        -DPLUGIN_PROVIDER_SNAPPY=NO
    make -j "$(nproc)"
    make install
}

# Finds an ARM library by name where Debian keeps them.
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

# Keeps only the programs the Intel build keeps (and mariadb-install-db), strips them and the plugins, and copies every
# library they need - and the ones those need in turn - into lib/runtime, with glibc's loader. Stops if one isn't
# found. (A queue in an array read from a file: with pipefail, a pipe into head can fail at random, and the chroot has
# no /dev/fd for <(...))
function bundle() {
    local queue name path program keep

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
    done

    # Only what the server and its tools need: no test suite, include files, man pages or sample configurations
    rm -rf ${PREFIX}/mariadb-test ${PREFIX}/mysql-test ${PREFIX}/sql-bench ${PREFIX}/include ${PREFIX}/man \
        ${PREFIX}/docs ${PREFIX}/support-files ${PREFIX}/lib/pkgconfig ${PREFIX}/lib/*.a ${PREFIX}/lib/*.so*
    ${HOST}-strip ${PREFIX}/bin/* ${PREFIX}/lib/plugin/*.so
    mkdir -p ${RUNTIME}
    : > /work/needed

    for program in ${PREFIX}/bin/* ${PREFIX}/lib/plugin/*.so; do
        needed "${program}" >> /work/needed
    done

    mapfile -t queue < /work/needed

    while [ ${#queue[@]} -gt 0 ]; do
        name="${queue[0]}"
        queue=("${queue[@]:1}")

        if [ -z "${name}" ] || [ -e "${RUNTIME}/${name}" ]; then
            continue
        fi

        path="$(find_library "${name}")"

        if [ -z "${path}" ]; then
            echo "Library not found: ${name}"

            exit 1
        fi

        cp -L "${path}" "${RUNTIME}/${name}"
        needed "${RUNTIME}/${name}" > /work/needed
        mapfile -t -O ${#queue[@]} queue < /work/needed
    done

    cp -L "$(find_library ${LOADER})" ${RUNTIME}/${LOADER}
}

# Points the programs at the bundled loader and libraries (by their full paths, through /usr/local/mysql, which the app
# links to these files), the plugins at the libraries, and each bundled library at the others ($ORIGIN: its own folder)
# - so that none of the NAS's own libraries is used. The NAS's ARM kernels use 64KB memory pages, so patchelf aligns
# what it adds to those.
function patch() {
    local file

    for file in ${RUNTIME}/*; do
        [ "$(basename "${file}")" = ${LOADER} ] && continue
        patchelf --page-size 65536 --set-rpath '$ORIGIN' "${file}"
    done

    for file in ${PREFIX}/bin/*; do
        patchelf --page-size 65536 --set-interpreter ${RUNTIME}/${LOADER} --set-rpath ${RUNTIME} "${file}"
    done

    for file in ${PREFIX}/lib/plugin/*.so; do
        patchelf --page-size 65536 --set-rpath ${RUNTIME} "${file}"
    done

    chmod 755 ${PREFIX}/bin/* ${RUNTIME}/${LOADER}
}

# Downloads the Debian source packages of the bundled libraries whose license asks for their source (GPL, LGPL, MPL - by
# their copyright files, which takes in some it needn't, rather than miss one) into /work/sources, and lists every
# bundled library's package in /work/sources/packages.tsv. GCC's runtime libraries are left out, as their license
# exempts what's built with them.
function sources() {
    local lib package source version license

    rm -rf /work/sources
    mkdir -p /work/sources
    printf 'library\tpackage\tsource\tversion\tlicense\n' > /work/sources/packages.tsv
    apt-get update

    for lib in ${RUNTIME}/*; do
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

build
bundle
patch
sources
