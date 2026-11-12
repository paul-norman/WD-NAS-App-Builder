#!/bin/bash

# Builds PHP's CLI and FPM for the ARM models (armhf), with every extension built in - the same ones as the Intel
# models' static build. Run by build.sh inside the Debian stage of the Dockerfile (with chroot), with what it needs in
# /work: PHP's source (php.tar.gz), the PECL extensions' (apcu.tgz, igbinary.tgz, redis.tgz, yaml.tgz) and GNU
# libiconv's (libiconv.tar.gz).
#
#     VERSION=<PHP's version> bash /work/armhf.sh
#
# PHP is compiled with Debian's cross-compiler (no emulation: minutes, not hours), against Debian's own builds of its
# libraries. Those libraries and Debian's glibc are bundled with it (binaries/runtime), as the NAS's own are too old:
# everything is prepared at the app's final path (/mnt/HD/HD_a2/Nas_Prog/php/binaries), and php and php-fpm are set to
# use the bundled glibc's loader by its full path. Leaves:
#  - /mnt/HD/HD_a2/Nas_Prog/php/binaries: php, php-fpm and runtime/
#  - /work/sources: the sources of the bundled libraries under a license that asks for them (Debian's source packages)

set -e
set -o pipefail
set -x

HOST=arm-linux-gnueabihf
BINARIES=/mnt/HD/HD_a2/Nas_Prog/php/binaries
RUNTIME=${BINARIES}/runtime
LOADER=ld-linux-armhf.so.3
# Where Debian keeps the ARM libraries (multiarch)
LIB_PATHS="/lib/${HOST} /usr/lib/${HOST}"
SOURCE=/work/php-${VERSION}

# Unpacks PHP and adds the PECL extensions to its ext/ folder, then regenerates its configure script with them.
function prepare() {
    local name

    rm -rf ${SOURCE}
    tar -xzf /work/php.tar.gz -C /work

    for name in apcu igbinary redis yaml; do
        mkdir -p ${SOURCE}/ext/${name}
        tar -xzf /work/${name}.tgz -C ${SOURCE}/ext/${name} --strip-components=1 --exclude=package.xml
    done

    cd ${SOURCE}
    ./buildconf --force
}

# Builds GNU libiconv (static, into /work/libiconv) for PHP's iconv: glibc's own needs its character set modules from
# Debian's folders, which the NAS doesn't have.
function build_libiconv() {
    rm -rf /work/libiconv /work/libiconv-src
    mkdir -p /work/libiconv-src
    tar -xzf /work/libiconv.tar.gz -C /work/libiconv-src --strip-components=1
    cd /work/libiconv-src
    ./configure --build=x86_64-linux-gnu --host=${HOST} --prefix=/work/libiconv --enable-static --disable-shared \
        --disable-nls
    make -j "$(nproc)"
    make install
}

# Configures and compiles PHP, with the same extensions as the Intel models' build (static/php/build.sh's EXTENSIONS),
# and the same php.ini locations. One difference, from Debian's libraries: Argon2 password hashes come from libargon2
# (Debian's OpenSSL 3.0 has no Argon2). Opcache's JIT has no 32-bit ARM support.
function build() {
    cd ${SOURCE}
    PKG_CONFIG_LIBDIR=/usr/lib/${HOST}/pkgconfig:/usr/share/pkgconfig \
        ./configure --build=x86_64-linux-gnu --host=${HOST} \
        --prefix=/usr/local --disable-all --disable-phpdbg --enable-cli --enable-fpm --disable-cgi --disable-embed \
        --with-config-file-path=/usr/local/etc/php --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-apcu --enable-bcmath --with-bz2 --enable-ctype --with-curl --enable-dom --enable-exif \
        --enable-fileinfo --enable-filter --with-zlib --enable-gd --with-freetype --with-jpeg --with-webp \
        --with-gettext --with-iconv=/work/libiconv --enable-mbstring --enable-mbregex --enable-mysqlnd --with-mysqli \
        --with-openssl --with-password-argon2 --enable-pdo --with-pdo-mysql --with-sqlite3 --with-pdo-sqlite \
        --enable-posix --with-libedit --enable-session --enable-simplexml --enable-tokenizer --enable-xml \
        --enable-xmlreader --enable-xmlwriter --enable-opcache --disable-opcache-jit --enable-intl \
        --enable-igbinary --enable-redis --enable-redis-session --enable-redis-igbinary --disable-redis-msgpack \
        --disable-redis-lzf --disable-redis-zstd --disable-redis-lz4 --with-sodium --with-zip --enable-sockets \
        --enable-pcntl --with-pgsql --with-pdo-pgsql --with-gmp --with-ldap --with-xsl --enable-soap --with-libxml \
        --enable-calendar --enable-ftp --enable-shmop --enable-sysvsem --enable-sysvshm --enable-sysvmsg --with-tidy \
        --with-yaml
    make -j "$(nproc)"
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

# Copies every library php and php-fpm need, and the ones those need in turn, into the runtime folder - with glibc's
# loader. Stops if one isn't found.
function bundle() {
    local queue name path

    rm -rf ${BINARIES}
    mkdir -p ${RUNTIME}
    ${HOST}-strip -o ${BINARIES}/php ${SOURCE}/sapi/cli/php
    ${HOST}-strip -o ${BINARIES}/php-fpm ${SOURCE}/sapi/fpm/php-fpm
    queue="$(needed ${BINARIES}/php; needed ${BINARIES}/php-fpm)"

    while [ -n "${queue}" ]; do
        name="$(echo "${queue}" | head -n 1)"
        queue="$(echo "${queue}" | tail -n +2)"
        [ -e "${RUNTIME}/${name}" ] && continue
        path="$(find_library "${name}")"

        if [ -z "${path}" ]; then
            echo "Library not found: ${name}"

            exit 1
        fi

        cp -L "${path}" "${RUNTIME}/${name}"
        queue="$(echo "${queue}"; needed "${RUNTIME}/${name}")"
        queue="$(echo "${queue}" | sed '/^$/d')"
    done

    cp -L "$(find_library ${LOADER})" ${RUNTIME}/${LOADER}
}

# Points php and php-fpm at the bundled loader and libraries (by their full paths), and each bundled library at the
# others ($ORIGIN: its own folder) - so that none of the NAS's own libraries is used. The NAS's ARM kernels use 64KB
# memory pages, so patchelf aligns what it adds to those.
function patch() {
    local lib

    for lib in ${RUNTIME}/*; do
        [ "$(basename "${lib}")" = ${LOADER} ] && continue
        patchelf --page-size 65536 --set-rpath '$ORIGIN' "${lib}"
    done

    for program in ${BINARIES}/php ${BINARIES}/php-fpm; do
        patchelf --page-size 65536 --set-interpreter ${RUNTIME}/${LOADER} --set-rpath ${RUNTIME} "${program}"
    done

    chmod 755 ${BINARIES}/php ${BINARIES}/php-fpm ${RUNTIME}/${LOADER}
}

# Downloads the Debian source packages of the bundled libraries whose license asks for their source (GPL, LGPL, MPL - by
# their copyright files, which takes in some it needn't, rather than miss one) into /work/sources, and lists every
# bundled library's package in /work/sources/packages.tsv. GCC's runtime libraries are left out, as their license
# exempts what's built with them.
function sources() {
    local lib package source version

    rm -rf /work/sources
    mkdir -p /work/sources
    printf 'library\tpackage\tsource\tversion\tlicense\n' > /work/sources/packages.tsv
    apt-get update

    for lib in ${RUNTIME}/*; do
        package="$(dpkg -S "*/$(basename "${lib}")" 2>/dev/null | grep ':armhf: ' | head -n 1 | sed 's/: .*//' || true)"

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

        if [ "${license}" = copyleft ] && ! echo "${source}" | grep -qE '^gcc(-[0-9]+)?$' \
            && [ ! -e "/work/sources/${source}_${version#*:}.dsc" ]; then
            (cd /work/sources && apt-get source --download-only "${source}=${version}")
        fi
    done

    rm -rf /var/lib/apt/lists/*
}

prepare
build_libiconv
build
bundle
patch
sources
