#!/bin/bash

# Prepares Forgejo for the NAS: its official static program, plus fully static builds of the tools it needs alongside it
# (the NAS has no git):
#  - git:           Git itself (Forgejo runs it for every repository operation), with HTTPS support (a minimal static
#                   curl, OpenSSL and zlib only) so that it can also clone from other servers - usable over SSH too. Built
#                   with a runtime prefix, so it finds its helpers and settings relative to wherever it's installed
#  - forgejo_runas: switches to Forgejo's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=15.0.10
FORGEJO_SHA256=0cccbd4b2451479ba71d4c50b04860de03ddc8441b77a90e29582275af5f1900
GIT_VERSION=2.56.0
GIT_SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3
CURL_VERSION=8.23.0
# (curl publishes GPG signatures: this download's was checked against Daniel Stenberg's key 27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2)
CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/forgejo/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
	cd ${BUILD_PATH}
	wget -q "$1" -O "$2"
	echo "$3  $2" | sha256sum -c -
}

function build_forgejo() {
	fetch "https://codeberg.org/forgejo/forgejo/releases/download/v${VERSION}/forgejo-${VERSION}-linux-amd64.xz" forgejo.xz ${FORGEJO_SHA256}
	xz -d forgejo.xz
	chmod 755 forgejo
}

function build_curl() {
	fetch "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" curl.tar.xz ${CURL_SHA256}
	tar -xJf curl.tar.xz
	cd curl-${CURL_VERSION}
	./configure --prefix=${BUILD_PATH}/curl --disable-shared --enable-static --with-openssl --with-zlib \
		--without-libpsl --without-brotli --without-zstd --without-libidn2 --without-nghttp2 --without-nghttp3 \
		--without-ngtcp2 --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
		--disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-manual --disable-docs \
		--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt
	make -j "$(nproc)"
	make install
}

function build_git() {
	fetch "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" git.tar.xz ${GIT_SHA256}
	tar -xJf git.tar.xz
	cd git-${GIT_VERSION}
	# Relative paths (RUNTIME_PREFIX): its helpers, templates and system settings are found next to bin/git, wherever it is.
	# (Git's own regex library: musl's lacks REG_STARTEND. Its optional Rust parts are left out)
	make -j "$(nproc)" prefix=/ RUNTIME_PREFIX=YesPlease gitexecdir=libexec/git-core sysconfdir=etc \
		NO_TCLTK=1 NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_EXPAT=1 NO_REGEX=NeedsStartEnd NO_RUST=1 INSTALL_SYMLINKS=1 \
		CURL_CONFIG=${BUILD_PATH}/curl/bin/curl-config CURL_LDFLAGS="$(${BUILD_PATH}/curl/bin/curl-config --static-libs)" \
		LDFLAGS=-static CFLAGS=-O2 \
		DESTDIR=${BUILD_PATH}/git-out install
	# Only what's needed to run it (no mail, git-daemon, Scalar, man pages, git-gui or web interface)
	rm -rf ${BUILD_PATH}/git-out/share/man ${BUILD_PATH}/git-out/share/gitweb ${BUILD_PATH}/git-out/share/git-gui \
		${BUILD_PATH}/git-out/bin/scalar ${BUILD_PATH}/git-out/libexec/git-core/scalar \
		${BUILD_PATH}/git-out/libexec/git-core/git-imap-send ${BUILD_PATH}/git-out/libexec/git-core/git-daemon
	find ${BUILD_PATH}/git-out -type f -perm -u+x -exec sh -c 'head -c 4 "$1" | grep -q ELF && strip "$1"' sh {} \;
	# Certificate authorities for HTTPS remotes, found relative to git (%(prefix) is its install folder)
	mkdir -p ${BUILD_PATH}/git-out/etc
	cp /etc/ssl/certs/ca-certificates.crt ${BUILD_PATH}/git-out/etc/
	printf '# The app'"'"'s system-wide Git settings\n[http]\n\tsslCAInfo = %%(prefix)/etc/ca-certificates.crt\n' > ${BUILD_PATH}/git-out/etc/gitconfig
	for program in ${BUILD_PATH}/git-out/bin/git ${BUILD_PATH}/git-out/libexec/git-core/git-remote-http; do
		if ldd "${program}" 2>&1 | grep -q "=>"; then
			echo "${program} isn't static"
			exit 1
		fi
	done
}

function build_runas() {
	cd ${BUILD_PATH}
	cat > forgejo_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: forgejo_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("forgejo_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("forgejo_runas: could not run the program");
	return 127;
}
C
	gcc -O2 -static -o forgejo_runas forgejo_runas.c
	strip forgejo_runas
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_forgejo
	build_curl
	build_git
	build_runas

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}
	cp ${BUILD_PATH}/forgejo ${BUILD_PATH}/forgejo_runas ${OUTPUT_PATH}/
	cp -a ${BUILD_PATH}/git-out ${OUTPUT_PATH}/git
	${OUTPUT_PATH}/forgejo --version
	${OUTPUT_PATH}/git/bin/git --version
	${OUTPUT_PATH}/git/bin/git config --system --get http.sslCAInfo
	du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/git

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
