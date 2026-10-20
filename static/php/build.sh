#!/bin/bash

# Builds PHP's CLI and FPM as fully static binaries with static-php-cli, with every extension built in: those of the
# NAS's own PHP 7.4 (so that it can replace it), plus opcache, intl, redis (for ValKey), sodium, zip, sockets and pcntl,
# and the other extensions popular PHP apps ask for (WordPress, Nextcloud, Laravel, Drupal...): PostgreSQL drivers, gmp,
# ldap, igbinary (also used by redis), xsl, soap, calendar, ftp, shared memory / semaphores, tidy and yaml.
# Static binaries can't load extensions from .so files, so none are needed (or possible)

set -e
set -o pipefail
set -x

VERSION=8.5.11
SPC_VERSION=2.8.5

# The NAS's PHP 7.4 extensions, then the extras
EXTENSIONS="apcu,bcmath,bz2,ctype,curl,dom,exif,fileinfo,filter,gd,gettext,iconv,mbstring,mysqli,mysqlnd,openssl,pdo,pdo_mysql,pdo_sqlite,posix,readline,session,simplexml,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib"
EXTENSIONS="${EXTENSIONS},opcache,intl,redis,sodium,zip,sockets,pcntl"
EXTENSIONS="${EXTENSIONS},pgsql,pdo_pgsql,gmp,ldap,igbinary,xsl,soap,calendar,ftp,shmop,sysvsem,sysvshm,sysvmsg,tidy,yaml"
# Image formats for gd
LIBS="freetype,libjpeg,libpng,libwebp"

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/php/${VERSION}/${ARCH}

function build_php() {
	cd ${BUILD_PATH}

	# static-php-cli itself (a single self-contained binary)
	wget -q "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-linux-$(uname -m).tar.gz" -O spc.tar.gz
	tar -xzf spc.tar.gz
	chmod +x spc

	# Build tools, then the sources (PHP pinned to this exact version)
	./spc doctor --auto-fix
	./spc download --for-extensions="${EXTENSIONS}" --for-libs="${LIBS}" \
		--custom-url="php-src:https://www.php.net/distributions/php-${VERSION}.tar.gz" --prefer-pre-built
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

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
