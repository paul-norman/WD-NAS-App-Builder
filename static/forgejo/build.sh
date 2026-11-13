#!/bin/bash

# Prepares Forgejo for the NAS - for the Intel models and the ARM ones: its official static program for each, plus
# fully static builds of the tools it needs alongside it (the NAS has no git):
#  - git:           Git itself (Forgejo runs it for every repository operation), with HTTPS support (a minimal static
#                   curl, OpenSSL and zlib only) so that it can also clone from other servers - usable over SSH too. Built
#                   with a runtime prefix, so it finds its helpers and settings relative to wherever it's installed
#  - forgejo_runas: switches to Forgejo's own user (the NAS has no su or similar) before running it

# The Intel build's tools use gcc, with Alpine's static OpenSSL and zlib. The ARM ones are cross-compiled on this (Intel)
# machine with Zig for the ARM models' ARMv7 processors (hard-float) - OpenSSL and zlib built from their source for them
# first - and every ARM program, Forgejo's own included, is checked for their kernels' large memory pages
# (ci/check_arm_pages.py) and run with QEMU's emulator. Each build is checked: Forgejo's version, and Git making a
# repository and a commit.

set -e
set -o pipefail
set -x

VERSION=15.0.11
# Each architecture's release, as its .sha256 file gives it (Forgejo's 32-bit ARM build is for ARMv6, which the ARMv7
# models run)
FORGEJO_SHA256=7328daf77cec27e17c9a34ed5d87cae690384b6d5e06bf831281c750c87303e0
FORGEJO_ARMHF_SHA256=e9d113cd4a11dc6d38e83895ff081c93a39f46c07482815d5b9fb07ba6058f5d
GIT_VERSION=2.56.0
GIT_SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3
CURL_VERSION=8.23.0
# cURL publishes GPG signatures: this download's was checked against Daniel Stenberg's key
# 27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2
CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
# OpenSSL and zlib for the ARM build (as the Nginx app's: OpenSSL's published SHA256, zlib's signature by Mark Adler)
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
# The architectures built (each into packages/static/forgejo/<version>/<arch>)
ARCHES='amd64 armhf'
ARM_HOST=arm-linux-musleabihf

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools

# Writes the ARM compiler's commands (Zig's, for the ARM models' processors): arm-cc, arm-ar and arm-ranlib.
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    printf '#!/bin/sh\nexec zig cc -target %s -mcpu=cortex_a9 "$@"\n' ${ARM_HOST} > ${TOOLS_PATH}/arm-cc
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/*
}

# Downloads every source into ${BUILD_PATH}, each checked against its SHA256.
function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://codeberg.org/forgejo/forgejo/releases/download/v${VERSION}/forgejo-${VERSION}-linux-amd64.xz" \
        forgejo-amd64.xz ${FORGEJO_SHA256}
    sh /data/static/fetch.sh \
        "https://codeberg.org/forgejo/forgejo/releases/download/v${VERSION}/forgejo-${VERSION}-linux-arm-6.xz" \
        forgejo-armhf.xz ${FORGEJO_ARMHF_SHA256}
    sh /data/static/fetch.sh "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" curl.tar.xz ${CURL_SHA256}
    sh /data/static/fetch.sh "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" git.tar.xz \
        ${GIT_SHA256}
    sh /data/static/fetch.sh \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl.tar.gz "${OPENSSL_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        zlib.tar.gz "${ZLIB_SHA256}"
}

# Sets up the build for an architecture (the variables every step below uses): its compilers, and where its libraries
# go (DEPS).
#
# $1 arch The architecture (amd64 or armhf)
function use_arch() {
    ARCH="$1"
    SRC=${BUILD_PATH}/${ARCH}
    DEPS=${SRC}/deps
    mkdir -p ${SRC}

    if [ "${ARCH}" = armhf ]; then
        export CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib
        STRIP=arm-none-eabi-strip
    else
        export CC=gcc AR=ar RANLIB=ranlib
        STRIP=strip
    fi
}

# Builds zlib and OpenSSL (its libraries only) for the ARM models, static, into ${DEPS}.
function build_arm_libraries() {
    cd ${SRC}
    tar -xzf ${BUILD_PATH}/zlib.tar.gz
    cd zlib-${ZLIB_VERSION}
    CFLAGS='-O2 -fPIC' ./configure --static --prefix=${DEPS}
    make -j "$(nproc)" libz.a
    make install

    cd ${SRC}
    tar -xzf ${BUILD_PATH}/openssl.tar.gz
    cd openssl-${OPENSSL_VERSION}
    # Only the libraries (no programs, tests or documents), with no loadable modules or engines
    ./Configure linux-armv4 --prefix=${DEPS} --libdir=lib --openssldir=/etc/ssl -O2 \
        no-shared no-module no-engine no-apps no-tests no-docs CC=${CC} AR=${AR} RANLIB=${RANLIB}
    make -j "$(nproc)" build_libs
    make install_dev
}

function build_curl() {
    local options=(--with-openssl --with-zlib)
    local environment=()

    # (the ARM build's OpenSSL and zlib found by pkg-config in its own folder only)
    if [ "${ARCH}" = armhf ]; then
        options=(--build=x86_64-alpine-linux-musl --host=${ARM_HOST} --with-openssl=${DEPS} --with-zlib=${DEPS})
        environment=(PKG_CONFIG_LIBDIR=${DEPS}/lib/pkgconfig)
    fi

    cd ${SRC}
    tar -xJf ${BUILD_PATH}/curl.tar.xz
    cd curl-${CURL_VERSION}
    env "${environment[@]}" ./configure --prefix=${SRC}/curl --disable-shared --enable-static "${options[@]}" \
        --without-libpsl --without-brotli --without-zstd --without-libidn2 --without-nghttp2 --without-nghttp3 \
        --without-ngtcp2 --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-manual --disable-docs \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt
    make -j "$(nproc)"
    make install
}

function build_git() {
    local out=${SRC}/git-out
    local cross=()

    # (Git has no configure step here: told what it builds for - otherwise it goes by this machine - and where the ARM
    # build's OpenSSL and zlib are. Without its fuzzing test programs, which aren't installed: their linker option is
    # one Zig doesn't take)
    if [ "${ARCH}" = armhf ]; then
        cross=(uname_S=Linux uname_M=armv7l uname_R=4.14 HOST_CPU=arm OPENSSLDIR=${DEPS} ZLIB_PATH=${DEPS}
            FUZZ_PROGRAMS=)
    fi

    cd ${SRC}
    tar -xJf ${BUILD_PATH}/git.tar.xz
    cd git-${GIT_VERSION}
    # Relative paths (RUNTIME_PREFIX): its helpers, templates and system settings are found next to bin/git, wherever it
    # is. (Git's own regex library: musl's lacks REG_STARTEND. Its optional Rust parts are left out)
    make -j "$(nproc)" "${cross[@]}" CC=${CC} AR=${AR} prefix=/ RUNTIME_PREFIX=YesPlease \
        gitexecdir=libexec/git-core sysconfdir=etc \
        NO_TCLTK=1 NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_EXPAT=1 NO_REGEX=NeedsStartEnd NO_RUST=1 INSTALL_SYMLINKS=1 \
        CURL_CONFIG=${SRC}/curl/bin/curl-config CURL_LDFLAGS="$(${SRC}/curl/bin/curl-config --static-libs)" \
        LDFLAGS=-static CFLAGS=-O2 \
        DESTDIR=${out} install
    # Only what's needed to run it (no mail, git-daemon, Scalar, man pages, git-gui or web interface)
    rm -rf ${out}/share/man ${out}/share/gitweb ${out}/share/git-gui ${out}/bin/scalar \
        ${out}/libexec/git-core/scalar ${out}/libexec/git-core/git-imap-send ${out}/libexec/git-core/git-daemon
    find ${out} -type f -perm -u+x -exec sh -c 'head -c 4 "$1" | grep -q ELF && '"${STRIP}"' "$1"' sh {} \;
    # Certificate authorities for HTTPS remotes, found relative to git (%(prefix) is its install folder)
    mkdir -p ${out}/etc
    cp /etc/ssl/certs/ca-certificates.crt ${out}/etc/
    printf '# The app'"'"'s system-wide Git settings\n[http]\n\tsslCAInfo = %%(prefix)/etc/ca-certificates.crt\n' \
        > ${out}/etc/gitconfig
}

function build_runas() {
    cd ${SRC}
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
    ${CC} -O2 -static -o forgejo_runas forgejo_runas.c
    ${STRIP} forgejo_runas
}

# Puts the architecture's programs together in ${SRC}/package: Forgejo's own release for it, the helper and Git.
function assemble() {
    local package=${SRC}/package

    mkdir -p ${package}
    xz -dc ${BUILD_PATH}/forgejo-${ARCH}.xz > ${package}/forgejo
    chmod 755 ${package}/forgejo
    cp ${SRC}/forgejo_runas ${package}/
    cp -a ${SRC}/git-out ${package}/git
}

# Checks the architecture's programs in ${SRC}/package: static (the ARM ones laid out for large memory pages), and
# working - Forgejo's version, the helper, Git making a repository and a commit and reading it back, and its settings
# file found relative to it - the ARM ones with QEMU.
function check() {
    local package=${SRC}/package
    local emulator=''
    local program usage git

    for program in forgejo forgejo_runas git/bin/git git/libexec/git-core/git-remote-http; do
        if ! file -L ${package}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${ARCH}) isn't static: $(file -L ${package}/${program})"

            exit 1
        fi
    done

    if [ "${ARCH}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${package}/forgejo ${package}/forgejo_runas ${package}/git/bin/git \
            ${package}/git/libexec/git-core/git-remote-http
        emulator='qemu-arm -cpu cortex-a9'
    fi

    ${emulator} ${package}/forgejo --version | grep "${VERSION}"
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(${emulator} ${package}/forgejo_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: forgejo_runas' > /dev/null

    # (single Git commands only, and no automatic maintenance after the commit: under QEMU, Git can't start another ARM
    # program - itself again, or its helpers)
    git="${emulator} ${package}/git/bin/git -c maintenance.auto=false -c gc.auto=0"
    ${git} --version | grep "git version ${GIT_VERSION}"
    [ "$(${git} config --system --get http.sslCAInfo)" = '%(prefix)/etc/ca-certificates.crt' ]
    rm -rf /tmp/git-test
    ${git} init -q -b main /tmp/git-test
    echo 'Grüße' > /tmp/git-test/hello.txt
    ${git} -C /tmp/git-test add hello.txt
    ${git} -C /tmp/git-test -c user.name=Check -c user.email=check@nas.local commit -q -m 'First commit'
    [ "$(${git} -C /tmp/git-test log --format=%s)" = 'First commit' ]
    [ "$(${git} -C /tmp/git-test show HEAD:hello.txt)" = 'Grüße' ]
}

function run() {
    local arch output

    # Clean start
    rm -rf ${BUILD_PATH}
    mkdir -p ${BUILD_PATH}

    download
    make_tools

    for arch in ${ARCHES}; do
        use_arch ${arch}
        [ "${arch}" = armhf ] && build_arm_libraries
        build_curl
        build_git
        build_runas
        assemble
        check

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/forgejo/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p $(dirname ${output})
        cp -a ${SRC}/package ${output}
        du -sh ${output} ${output}/git
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/forgejo/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
