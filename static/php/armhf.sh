#!/bin/bash

# Builds PHP's CLI and FPM for the ARM models (armhf) as fully static programs, with every extension built in - the same
# ones as the Intel models' static build. Run by build.sh in this image, with the sources in ${WORK} (php.tar.gz, the
# PECL extensions' apcu.tgz, igbinary.tgz, redis.tgz and yaml.tgz, and libiconv.tar.gz, gmp.tar.xz, libzip.tar.xz,
# brotli.tar.gz, libwebp.tar.gz, curl.tar.xz and openldap.tgz):
#
#     VERSION=<PHP's version> WORK=<folder> bash armhf.sh
#
# The ARM models' kernels use large memory pages (32KB on the EX2 Ultra), and programs laid out for 4KB pages - as
# Debian's and Alpine's ARM programs and shared libraries are - crash there. A static program is laid out by its final
# link: PHP is cross-compiled with clang and linked by LLD (which lays programs out for 64KB pages), against Alpine's
# own static ARM libraries (the Alpine ARM system in /armv7, from the Dockerfile) and a few built here from their source
# into it (GNU libiconv, GMP and libzip, which Alpine has no static libraries of). configure's test programs run with
# QEMU's emulator, so that its checks get the ARM models' real answers. Leaves ${WORK}/out/php and ${WORK}/out/php-fpm.

set -e
set -o pipefail
set -x

TARGET=armv7-alpine-linux-musleabihf
SYSROOT=/armv7
TOOLS=${WORK}/tools
SOURCE=${WORK}/php-${VERSION}
# Built from source into the Alpine ARM system, where its pkg-config finds them
DEPS=/usr/local

# The cross-compiling tools: cc and c++ (clang for the ARM models, against the Alpine ARM system, linked by LLD), each
# turning a test program it links (conftest) into a script running it with QEMU; pkg-config (the Alpine ARM system's
# libraries, with what their static libraries need); a CMake toolchain file.
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
            echo "${compiler#*:} --target=${TARGET} --sysroot=${SYSROOT} -mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments \"\$@\" || exit \$?"
            echo 'case "${out}" in'
            echo '    conftest|*/conftest)'
            echo '        mv "${out}" "${out}.arm"'
            echo "        printf '#!/bin/sh\\nexec qemu-arm -cpu cortex-a9 %s \"\$@\"\\n' \"\$(cd \"\$(dirname \"\${out}\")\" && pwd)/\$(basename \"\${out}\").arm\" > \"\${out}\""
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
    chmod 755 ${TOOLS}/cc ${TOOLS}/c++ ${TOOLS}/pkg-config

    {
        echo 'set(CMAKE_SYSTEM_NAME Linux)'
        echo 'set(CMAKE_SYSTEM_PROCESSOR arm)'
        echo "set(CMAKE_C_COMPILER ${TOOLS}/cc)"
        echo "set(CMAKE_CXX_COMPILER ${TOOLS}/c++)"
        echo "set(CMAKE_SYSROOT ${SYSROOT})"
        echo "set(CMAKE_FIND_ROOT_PATH ${SYSROOT})"
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)'
        echo "set(PKG_CONFIG_EXECUTABLE ${TOOLS}/pkg-config)"
    } > ${WORK}/toolchain.cmake
}

# Unpacks a source archive from ${WORK} into a folder of ${WORK}: $1 = the archive's name, $2 = the folder.
function unpack() {
    rm -rf ${WORK}/$2
    mkdir -p ${WORK}/$2
    tar -xf ${WORK}/$1 -C ${WORK}/$2 --strip-components=1
}

# The libraries Alpine has no usable static ARM libraries of, built into the Alpine ARM system (${DEPS} in it): GNU
# libiconv (PHP's iconv, as the Intel build has: musl's is limited), GMP, libzip, Brotli (FreeType's WOFF2 fonts),
# libwebp (gd's WebP images), curl (with OpenSSL and zlib only) and OpenLDAP's client libraries (with OpenSSL, without
# SASL - Alpine's static SASL library needs GDBM and Kerberos too).
function build_libraries() {
    export PATH="${TOOLS}:${PATH}"

    unpack brotli.tar.gz brotli
    cmake -S ${WORK}/brotli -B ${WORK}/brotli/build -DCMAKE_TOOLCHAIN_FILE=${WORK}/toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${DEPS} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
        -DBROTLI_DISABLE_TESTS=ON
    cmake --build ${WORK}/brotli/build -j "$(nproc)"
    DESTDIR=${SYSROOT} cmake --install ${WORK}/brotli/build

    unpack libwebp.tar.gz libwebp
    cmake -S ${WORK}/libwebp -B ${WORK}/libwebp/build -DCMAKE_TOOLCHAIN_FILE=${WORK}/toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${DEPS} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF
    cmake --build ${WORK}/libwebp/build -j "$(nproc)"
    DESTDIR=${SYSROOT} cmake --install ${WORK}/libwebp/build

    unpack curl.tar.xz curl
    cd ${WORK}/curl
    CC=cc ./configure --host=${TARGET} --prefix=${DEPS} --enable-static --disable-shared --with-openssl --with-zlib \
        --without-brotli --without-zstd --without-libpsl --without-libidn2 --without-nghttp2 --without-nghttp3 \
        --without-ngtcp2 --disable-ldap --disable-manual --disable-docs --without-ca-bundle --with-ca-fallback
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    # (its configure won't test, when cross-compiling, whether select() yields to other threads, or whether memcmp()
    # works - assuming not, and using its own, which libldap then can't find: on Linux, with musl, both do)
    unpack openldap.tgz openldap
    cd ${WORK}/openldap
    CC=cc ./configure --host=${TARGET} --prefix=${DEPS} --enable-static --disable-shared --disable-slapd \
        --without-cyrus-sasl --with-tls=openssl --with-yielding_select=yes ac_cv_func_memcmp_working=yes
    make depend
    make -C libraries -j "$(nproc)"
    make -C include install DESTDIR=${SYSROOT}
    make -C libraries install DESTDIR=${SYSROOT}

    unpack libiconv.tar.gz libiconv
    cd ${WORK}/libiconv
    CC=cc ./configure --host=${TARGET} --prefix=${DEPS} --enable-static --disable-shared --disable-nls
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    unpack gmp.tar.xz gmp
    cd ${WORK}/gmp
    CC=cc ./configure --host=${TARGET} --prefix=${DEPS} --enable-static --disable-shared
    make -j "$(nproc)"
    make install DESTDIR=${SYSROOT}

    unpack libzip.tar.xz libzip
    cmake -S ${WORK}/libzip -B ${WORK}/libzip/build -DCMAKE_TOOLCHAIN_FILE=${WORK}/toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${DEPS} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=ON \
        -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
    cmake --build ${WORK}/libzip/build -j "$(nproc)"
    DESTDIR=${SYSROOT} cmake --install ${WORK}/libzip/build

    # libtool's records of them name their dependencies' paths on the NAS, not in the Alpine ARM system, which libtool
    # then can't find when linking PHP: pkg-config's tell it the same
    rm -f ${SYSROOT}${DEPS}/lib/*.la

    build_icu_data
}

# ICU's data (locales, collation, time zones...) built into PHP: Alpine keeps it in a file of its own (icu-data-full's
# icudt<version>l.dat, which the NAS wouldn't have), and its static libicudata is only a placeholder for it - one symbol,
# icudt<version>_dat. The file becomes that symbol (an ARM object including it whole), in place of the placeholder.
function build_icu_data() {
    local data symbol

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
    } > ${WORK}/icudata.S
    ${TOOLS}/cc -c ${WORK}/icudata.S -o ${WORK}/icudata.o
    rm -f ${SYSROOT}/usr/lib/libicudata.a
    arm-none-eabi-ar rcs ${SYSROOT}/usr/lib/libicudata.a ${WORK}/icudata.o
}

# Unpacks PHP and adds the PECL extensions to its ext/ folder, then regenerates its configure script with them. Also
# corrects Alpine's libpq.pc for a static link: its client library needs PostgreSQL's helper libraries' _shlib versions
# (built for libraries, with pg_char_to_encoding()), not the ones it names.
function prepare() {
    grep '^Libs.private:.*-lpgcommon -lpgport ' ${SYSROOT}/usr/lib/pkgconfig/libpq.pc > /dev/null
    sed -i 's/-lpgcommon -lpgport /-lpgcommon_shlib -lpgport_shlib /' ${SYSROOT}/usr/lib/pkgconfig/libpq.pc

    local name

    rm -rf ${SOURCE}
    tar -xzf ${WORK}/php.tar.gz -C ${WORK}

    for name in apcu igbinary redis yaml; do
        mkdir -p ${SOURCE}/ext/${name}
        tar -xzf ${WORK}/${name}.tgz -C ${SOURCE}/ext/${name} --strip-components=1 --exclude=package.xml
    done

    cd ${SOURCE}
    ./buildconf --force
}

# Configures and compiles PHP, with the same extensions and php.ini locations as the Intel models' build (static/php's
# EXTENSIONS) - Argon2 password hashes from OpenSSL, iconv from GNU libiconv, as there. Opcache's JIT has no 32-bit ARM
# support. Linked fully static (-all-static: libtool's way of saying so for programs). (LDAP without a folder: then PHP
# asks pkg-config, which gives what OpenLDAP's static libraries need: OpenSSL.)
function build() {
    cd ${SOURCE}
    CC=${TOOLS}/cc CXX=${TOOLS}/c++ PKG_CONFIG=${TOOLS}/pkg-config LDFLAGS=-static \
        ./configure --host=${TARGET} \
        --prefix=/usr/local --disable-all --disable-phpdbg --enable-cli --enable-fpm --disable-cgi --disable-embed \
        --with-config-file-path=/usr/local/etc/php --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-apcu --enable-bcmath --with-bz2=${SYSROOT}/usr --enable-ctype --with-curl --enable-dom --enable-exif \
        --enable-fileinfo --enable-filter --with-zlib --enable-gd --with-freetype --with-jpeg --with-webp \
        --with-gettext=${SYSROOT}/usr --with-iconv=${SYSROOT}${DEPS} --enable-mbstring --enable-mbregex \
        --enable-mysqlnd --with-mysqli --with-openssl --with-openssl-argon2 --enable-pdo --with-pdo-mysql \
        --with-sqlite3 --with-pdo-sqlite --enable-posix --with-libedit --enable-session --enable-simplexml \
        --enable-tokenizer --enable-xml --enable-xmlreader --enable-xmlwriter --enable-opcache --disable-opcache-jit \
        --enable-intl --enable-igbinary --enable-redis --enable-redis-session --enable-redis-igbinary \
        --disable-redis-msgpack --disable-redis-lzf --disable-redis-zstd --disable-redis-lz4 --with-sodium --with-zip \
        --enable-sockets --enable-pcntl --with-pgsql --with-pdo-pgsql --with-gmp=${SYSROOT}${DEPS} \
        --with-ldap --with-xsl --enable-soap --with-libxml --enable-calendar --enable-ftp --enable-shmop \
        --enable-sysvsem --enable-sysvshm --enable-sysvmsg --with-tidy=${SYSROOT}/usr --with-yaml=${SYSROOT}/usr
    # (-all-static added to what configure put in EXTRA_LDFLAGS_PROGRAM - its libraries' folders - not in its place)
    make -j "$(nproc)" EXTRA_LDFLAGS_PROGRAM="-all-static $(sed -n 's/^EXTRA_LDFLAGS_PROGRAM = //p' Makefile)"

    mkdir -p ${WORK}/out
    arm-none-eabi-strip -o ${WORK}/out/php sapi/cli/php
    arm-none-eabi-strip -o ${WORK}/out/php-fpm sapi/fpm/php-fpm
}

make_tools
build_libraries
prepare
build
