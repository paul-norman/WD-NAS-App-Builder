#!/bin/bash

set -e
set -o pipefail
set -x

MUSL_VERSION=1.2.5
NCURSES_VERSION=6.3
NANO_VERSION=8.3

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/nano/${NANO_VERSION}/${ARCH}

function build_musl() {
	cd ${BUILD_PATH}

	# Download
	curl -LO https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz
	tar zxvf musl-${MUSL_VERSION}.tar.gz
	cd musl-${MUSL_VERSION}

	# Configure
	./configure
	
	# Make
	make -j4
	make install
}

function build_ncurses() {
	cd ${BUILD_PATH}

	# Download
	curl -LO https://invisible-island.net/datafiles/release/ncurses.tar.gz
	tar zxvf ncurses.tar.gz
	cd ncurses-${NCURSES_VERSION}

	# Configure
	CC='/usr/local/musl/bin/musl-gcc -static' \
	CFLAGS='-fPIC' \
	./configure \
		--prefix=/usr \
		--disable-shared \
		--enable-static \
		--with-normal \
		--without-debug \
		--without-ada \
		--with-default-terminfo=/usr/share/terminfo \
		--with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo"

	# Make
	mkdir "${BUILD_PATH}/ncurses-install"
	make DESTDIR="${BUILD_PATH}/ncurses-install" \
		install.libs install.includes
}

function build_nano() {
	cd ${BUILD_PATH}

	# Download
	curl -LO https://www.nano-editor.org/dist/v${NANO_VERSION%.*}/nano-${NANO_VERSION}.tar.xz
	tar xJvf nano-${NANO_VERSION}.tar.xz
	cd nano-${NANO_VERSION}
	
	# Add in missing header from OS
	mkdir -p ${BUILD_PATH}/ncurses-install/usr/include/linux
	ln -sf /usr/include/linux/vt.h ${BUILD_PATH}/ncurses-install/usr/include/linux/vt.h

	# Configure
	CC='/usr/local/musl/bin/musl-gcc -static' \
	CFLAGS="-fPIC" \
	CPPFLAGS="-I${BUILD_PATH}/ncurses-install/usr/include" \
	LDFLAGS="-L${BUILD_PATH}/ncurses-install/usr/lib" \
	./configure \
		--disable-nls \
		--disable-dependency-tracking

	# Make
	make -j4
	strip src/nano
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_musl
	build_ncurses
	build_nano
	
	# Copy to output
	mkdir -p $OUTPUT_PATH
	cp ${BUILD_PATH}/nano-${NANO_VERSION}/src/nano ${OUTPUT_PATH}/
	
	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${NANO_VERSION}" > ${LATEST_PATH}
	
	chown -R 1000:1000 /data/packages;
}

run