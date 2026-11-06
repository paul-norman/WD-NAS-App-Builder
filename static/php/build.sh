#!/bin/bash

# Builds PHP's CLI and FPM as fully static binaries with static-php-cli, with every extension built in: those of the
# NAS's own PHP 7.4 (so that it can replace it), plus opcache, intl, redis (for ValKey), sodium, zip, sockets and pcntl,
# and the other extensions popular PHP apps ask for (WordPress, Nextcloud, Laravel, Drupal...): PostgreSQL drivers, gmp,
# ldap, igbinary (also used by redis), xsl, soap, calendar, ftp, shared memory / semaphores, tidy, yaml, and mbstring's
# regular expressions (mbregex, with the Oniguruma library: mb_split(), mb_ereg()... - Laravel uses mb_split()).
# Static binaries can't load extensions from .so files, so none are needed (or possible)

set -e
set -o pipefail
set -x

VERSION=8.5.12
# php.net's published SHA256 of the source (php-${VERSION}.tar.gz), checked before building
PHP_SHA256=81a0f450349e84b08eb43faa85f8a4c835684f3cc1c50471775d1317a046c525
SPC_VERSION=2.8.5
# Its x86_64 binary's digest, as GitHub publishes it for the release
SPC_SHA256=523ba4279c54c7a377156c0dd3a36adf92ee64b01e9a7f5e9e2ec084b8e458e5

# The NAS's PHP 7.4 extensions, then the extras
EXTENSIONS='apcu,bcmath,bz2,ctype,curl,dom,exif,fileinfo,filter,gd,gettext,iconv,mbstring,mysqli,mysqlnd,openssl,pdo,pdo_mysql,pdo_sqlite,posix,readline,session,simplexml,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib'
EXTENSIONS="${EXTENSIONS},opcache,intl,redis,sodium,zip,sockets,pcntl"
EXTENSIONS="${EXTENSIONS},pgsql,pdo_pgsql,gmp,ldap,igbinary,xsl,soap,calendar,ftp,shmop,sysvsem,sysvshm,sysvmsg,tidy,yaml"
EXTENSIONS="${EXTENSIONS},mbregex"
# Image formats for gd
LIBS='freetype,libjpeg,libpng,libwebp'

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/php/${VERSION}/${ARCH}

function build_php() {
    cd ${BUILD_PATH}

    # static-php-cli itself (a single self-contained binary)
    sh /data/static/fetch.sh \
        "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-linux-$(uname -m).tar.gz" \
        spc.tar.gz "${SPC_SHA256}"
    tar -xzf spc.tar.gz
    chmod +x spc

    # Build tools, then the sources (PHP pinned to this exact version). Every library is built from its source (not
    # static-php-cli's pre-built ones), so that the sources kept below are exactly what's in the binaries
    ./spc doctor --auto-fix
    ./spc download --for-extensions="${EXTENSIONS}" --for-libs="${LIBS}" \
        --custom-url="php-src:https://www.php.net/distributions/php-${VERSION}.tar.gz"
    # Stops the build if the source isn't there under its own name, rather than skipping the check
    echo "${PHP_SHA256}  downloads/php-${VERSION}.tar.gz" | sha256sum -c -
    ./spc build "${EXTENSIONS}" --with-libs="${LIBS}" --build-cli --build-fpm
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_php

    # Copy to output
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/buildroot/bin/php ${BUILD_PATH}/buildroot/bin/php-fpm ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/php -v
    ${OUTPUT_PATH}/php -m > ${OUTPUT_PATH}/extensions.txt

    # The sources of PHP and the libraries built into it, for the app's releases (ci/README.md, Sources)
    rm -rf ${OUTPUT_PATH}.sources
    mkdir -p ${OUTPUT_PATH}.sources/spc-downloads
    # (archives, folders of sources checked out, and static-php-cli's record of their versions: .lock.json)
    cp -r ${BUILD_PATH}/downloads/. ${OUTPUT_PATH}.sources/spc-downloads/
    du -sh ${OUTPUT_PATH}.sources

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
