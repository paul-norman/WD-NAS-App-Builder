#!/bin/bash

# Builds Ruby for the NAS, from its source, on the NAS's Debian version (so it needs only the NAS's glibc), with the
# libraries its standard extensions use built in: OpenSSL (openssl, net/https), libyaml (psych: YAML), libffi
# (fiddle) and zlib. Relocatable (--enable-load-relative): its commands (gem, bundle, irb...) find Ruby next to them.
# Plus:
#  - etc/cacert.pem: Mozilla's certificate authorities, as curl publishes them, which Ruby's OpenSSL trusts
#  - rubygems/defaults/operating_system.rb (static/ruby/operating_system.rb): gems installed in the app's data folder,
#    their commands linked into /usr/bin, and that bundle used

set -e
set -o pipefail
set -x

VERSION=4.0.9
# Ruby's published SHA256 (ruby-lang.org's releases list and cache.ruby-lang.org's index agree)
RUBY_SHA256=a8057adb39f51ad6dc3106237504c93dd792bb515837b4fe7817ae21ed7e51f4
# As the Nginx app has them (OpenSSL's published SHA256; zlib checked against Mark Adler's signature)
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
# Their releases publish no checksums: both match Alpine's packages' (SHA512), and libyaml's its widely published one
LIBYAML_VERSION=0.2.5
LIBYAML_SHA256=c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
LIBFFI_VERSION=3.8.0
LIBFFI_SHA256=7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4
# curl's copy of Mozilla's certificate authorities (a dated file, as curl publishes its SHA256)
CACERT_DATE=2026-10-20
CACERT_SHA256=796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
DEPS=${BUILD_PATH}/deps
# Where the app installs it on the NAS (relocatable all the same)
PREFIX=/mnt/HD/HD_a2/Nas_Prog/ruby/binaries
OUTPUT_PATH=/data/packages/static/ruby/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# The libraries, static and position-independent (they end up in Ruby's extensions)
function build_libraries() {
    fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        zlib-${ZLIB_VERSION}.tar.gz ${ZLIB_SHA256}
    tar -xzf zlib-${ZLIB_VERSION}.tar.gz
    cd zlib-${ZLIB_VERSION}
    CFLAGS='-O2 -fPIC' ./configure --static --prefix=${DEPS}
    make -j "$(nproc)" && make install

    # Its certificates where a NAS keeps them (/etc/ssl) - the app's bundle is used instead (operating_system.rb)
    fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl-${OPENSSL_VERSION}.tar.gz ${OPENSSL_SHA256}
    tar -xzf openssl-${OPENSSL_VERSION}.tar.gz
    cd openssl-${OPENSSL_VERSION}
    ./Configure linux-x86_64 no-shared no-tests no-docs -fPIC --prefix=${DEPS} --libdir=lib --openssldir=/etc/ssl
    make -j "$(nproc)" && make install_sw

    fetch "https://github.com/yaml/libyaml/releases/download/${LIBYAML_VERSION}/yaml-${LIBYAML_VERSION}.tar.gz" \
        yaml-${LIBYAML_VERSION}.tar.gz ${LIBYAML_SHA256}
    tar -xzf yaml-${LIBYAML_VERSION}.tar.gz
    cd yaml-${LIBYAML_VERSION}
    ./configure --prefix=${DEPS} --disable-shared --enable-static --with-pic
    make -j "$(nproc)" && make install

    fetch "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" \
        libffi-${LIBFFI_VERSION}.tar.gz ${LIBFFI_SHA256}
    tar -xzf libffi-${LIBFFI_VERSION}.tar.gz
    cd libffi-${LIBFFI_VERSION}
    ./configure --prefix=${DEPS} --disable-shared --enable-static --with-pic --disable-docs
    make -j "$(nproc)" && make install
}

function build_ruby() {
    fetch "https://cache.ruby-lang.org/pub/ruby/${VERSION%.*}/ruby-${VERSION}.tar.xz" ruby-${VERSION}.tar.xz ${RUBY_SHA256}
    tar -xJf ruby-${VERSION}.tar.xz
    cd ruby-${VERSION}
    # Its extensions link the libraries above in (a static OpenSSL also needs libdl and libpthread); no documentation
    # (the NAS has no use for ri)
    PKG_CONFIG_PATH=${DEPS}/lib/pkgconfig ./configure --prefix=${PREFIX} --enable-load-relative --disable-install-doc \
        --with-openssl-dir=${DEPS} --with-libyaml-dir=${DEPS} --with-libffi-dir=${DEPS} --with-zlib-dir=${DEPS} \
        CC=gcc CFLAGS='-O2' LIBS='-ldl -lpthread'
    make -j "$(nproc)"
    make install DESTDIR=${BUILD_PATH}/out

    # (Relocatable, it's installed at the top of DESTDIR rather than under its prefix)
    local ruby_home
    ruby_home="$(dirname "$(dirname "$(find ${BUILD_PATH}/out -path '*/bin/ruby' -type f | head -n 1)")")"
    echo "${ruby_home}" > ${BUILD_PATH}/ruby_home
    local ruby_lib=${ruby_home}/lib/ruby/$(${ruby_home}/bin/ruby -e 'print RbConfig::CONFIG["ruby_version"]')

    mkdir -p ${ruby_lib}/rubygems/defaults
    cp /data/static/ruby/operating_system.rb ${ruby_lib}/rubygems/defaults/operating_system.rb
    mkdir -p ${ruby_home}/etc
    fetch "https://curl.se/ca/cacert-${CACERT_DATE}.pem" cacert.pem ${CACERT_SHA256}
    cp ${BUILD_PATH}/cacert.pem ${ruby_home}/etc/cacert.pem

    # Smaller: without debugging symbols
    strip ${ruby_home}/bin/ruby
    find ${ruby_home}/lib -name '*.so' -exec strip --strip-unneeded {} +

    # Every standard extension there, and none needing the build's libraries (they're linked in)
    ${ruby_home}/bin/ruby -e 'require "openssl"; require "psych"; require "fiddle"; require "zlib"; require "socket"
        require "io/console"; require "json"; require "digest"; require "ripper"; require "net/http"
        puts "#{RUBY_DESCRIPTION} - #{OpenSSL::OPENSSL_LIBRARY_VERSION}, libyaml #{Psych::LIBYAML_VERSION}, zlib #{Zlib::ZLIB_VERSION}"'

    if find ${ruby_home} -name '*.so' -exec ldd {} \; 2>/dev/null | grep -E 'libssl|libcrypto|libyaml|libffi|libz\.'; then
        echo 'An extension needs a library the NAS may not have'

        exit 1
    fi
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_libraries
    build_ruby

    # Nothing may differ only in case: a Windows drive holding the repository can't store that
    local ruby_home
    ruby_home="$(cat ${BUILD_PATH}/ruby_home)"

    if [ -n "$(find ${ruby_home} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${ruby_home} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${ruby_home}/. ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/bin/ruby --version
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
