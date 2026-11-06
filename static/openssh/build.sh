#!/bin/bash

# Prepares OpenSSH for the NAS - for the Intel models and the ARM ones (its release, checked against its SHA256 - also
# signed by OpenSSH's release key), fully static (musl, with OpenSSL's libcrypto for RSA keys - the NAS's host key and
# most users' keys - and zlib):
#  - sshd, sshd-session, sshd-auth: the server - the listener and the per-connection programs it runs (from libexec)
#  - sftp-server:                   SFTP (WD's sshd_config names /usr/bin/sftp-server, which the app links to it)
#  - ssh, sftp, ssh-keygen:         the app's own checks (a trial login with a throwaway key before switching) and
#                                    the page's (fingerprints of the keys added)
#  - seccomp_check:                  whether the NAS's kernel can run OpenSSH's seccomp sandbox. Since 10.4 sshd stops
#                                    when it can't, and WD's kernel doesn't say whether it has seccomp filters, so the
#                                    pre-login program (sshd-auth, the only one with the sandbox) is built twice:
#                                    libexec (seccomp sandbox) and libexec-nosandbox (no system call filter - privilege
#                                    separation still applies: the pre-login part runs as its own user, shut in
#                                    /var/empty), chosen at every start.
#                                    (OpenSSH's rlimit sandbox isn't an option: its configure check fails on musl)
# It's built for /usr/local/openssh, a link to the app's binaries made at every start (where sshd finds its helpers),
# with its own unprivileged user for privilege separation: WD's "sshd" user is the login user, with root's ID
#
# The ARM models' parts are built on this (Intel) machine, cross-compiled with Zig for their ARMv7 processors
# (hard-float) - with OpenSSL and zlib built for them from source (Alpine's are the Intel machine's) - and checked with
# QEMU's emulator. Each architecture's build is checked with a real login: its ssh into its sshd, with a throwaway key.

set -e
set -o pipefail
set -x

# The app's version, and OpenSSH's (10.6p2 = OpenSSH 10.6, portable release 2)
VERSION=10.6.2
OPENSSH_VERSION=10.6p2
SHA256=9ae44872090cf2f06b3cf9ff147e7f16f309671340763ed2f99248398ae29d5b
PRIVSEP_USER=sshpriv
# The ARM models' OpenSSL (its libcrypto) and zlib (the Intel models' are Alpine's), as their releases publish them
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
# The architectures built (each into packages/static/openssh/<version>/<arch>)
ARCHES='amd64 armhf'
ARM_HOST=arm-linux-musleabihf

BUILD_PATH=/build
# The ARM compiler and its tools, as commands (for configure scripts)
TOOLS_PATH=${BUILD_PATH}/tools

# Downloads a file into the build folder and checks it against its SHA256
fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Runs a program built for an architecture here (an ARM one with QEMU's emulator, as a Cortex-A9 - the ARM models'
# processors' kind).
#
# $1 arch The architecture (amd64 or armhf)
# $@      The program and its arguments
run_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 "$@"
    else
        "$@"
    fi
}

# Writes the ARM compiler's commands (Zig's, for the ARM models' processors): arm-cc, arm-ar and arm-ranlib.
make_tools() {
    mkdir -p ${TOOLS_PATH}
    printf '#!/bin/sh\nexec zig cc -target %s -mcpu=cortex_a9 "$@"\n' ${ARM_HOST} > ${TOOLS_PATH}/arm-cc
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/*
}

# Builds zlib and OpenSSL's libcrypto for the ARM models, static, into ${BUILD_PATH}/armhf/deps.
build_arm_libraries() {
    local deps=${BUILD_PATH}/armhf/deps

    mkdir -p ${BUILD_PATH}/armhf
    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/zlib.tar.gz
    cd zlib-${ZLIB_VERSION}
    CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib CFLAGS=-O2 \
        ./configure --static --prefix=${deps}
    make -j "$(nproc)" libz.a
    make install

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/openssl.tar.gz
    cd openssl-${OPENSSL_VERSION}
    # Only the library (no programs, tests or documents), with no loadable modules or engines
    ./Configure linux-armv4 --prefix=${deps} --libdir=lib --openssldir=/etc/ssl -O2 \
        no-shared no-module no-engine no-apps no-tests no-docs \
        CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib
    make -j "$(nproc)" build_libs
    make install_dev
}

# Builds OpenSSH for an architecture, into ${BUILD_PATH}/<arch>/out.
#
# $1 arch The architecture (amd64 or armhf)
build_openssh() {
    local arch="$1"
    local out=${BUILD_PATH}/${arch}/out
    local cross=''
    local tools=''
    local cc=gcc

    # (the Intel build with Alpine's own compiler, OpenSSL and zlib)
    if [ "${arch}" = armhf ]; then
        cross="--build=x86_64-linux-musl --host=${ARM_HOST} --with-ssl-dir=${BUILD_PATH}/armhf/deps"
        cross="${cross} --with-zlib=${BUILD_PATH}/armhf/deps"
        tools="CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib"
        cc=${TOOLS_PATH}/arm-cc
    fi

    mkdir -p ${BUILD_PATH}/${arch}
    cd ${BUILD_PATH}/${arch}
    tar -xzf ${BUILD_PATH}/openssh.tar.gz
    cd openssh-${OPENSSH_VERSION}

    # No PAM, utmp, wtmp or lastlog: WD's sshd uses none - passwords are checked against /etc/shadow - and musl's login
    # records are stubs (the pre-login program without a sandbox first, then everything with the seccomp sandbox)
    configure() {
        # shellcheck disable=SC2086
        env ${tools} ./configure ${cross} \
            --prefix=/usr/local/openssh --libexecdir=/usr/local/openssh/libexec --sysconfdir=/etc/ssh \
            --with-privsep-user=${PRIVSEP_USER} --with-privsep-path=/var/empty --with-pid-dir=/var/run \
            --without-pam --disable-utmp --disable-wtmp --disable-lastlog --disable-utmpx --disable-wtmpx \
            --with-sandbox=$1 --with-ldflags=-static
    }

    configure no
    make -j "$(nproc)" sshd-auth
    mkdir -p ${out}/bin ${out}/libexec ${out}/libexec-nosandbox
    cp sshd-auth ${out}/libexec-nosandbox/
    make distclean
    configure seccomp_filter
    make -j "$(nproc)" sshd sshd-session sshd-auth sftp-server ssh sftp ssh-keygen

    for program in sshd ssh sftp ssh-keygen; do
        cp ${program} ${out}/bin/
    done

    for program in sshd-session sshd-auth sftp-server; do
        cp ${program} ${out}/libexec/
    done

    # seccomp_check: exits 0 when a seccomp filter (allowing everything) can be applied, as OpenSSH's sandbox applies
    # its own
    cat > seccomp_check.c <<'EOF2'
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>

int main(void)
{
	struct sock_filter allow[] = { BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW) };
	struct sock_fprog program = { .len = 1, .filter = allow };
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
		return 1;
	}
	return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) == 0 ? 0 : 2;
}
EOF2
    ${cc} -O2 -static -o ${out}/bin/seccomp_check seccomp_check.c

    if [ "${arch}" = armhf ]; then
        arm-none-eabi-strip ${out}/bin/* ${out}/libexec/* ${out}/libexec-nosandbox/*
    else
        strip ${out}/bin/* ${out}/libexec/* ${out}/libexec-nosandbox/*
    fi

    cp LICENCE ${out}/LICENCE
}

# Checks an architecture's build: every program fully static, none looking users up through NSS (musl has none), and
# a real login - its ssh into its sshd on a spare port, with throwaway keys (an RSA host key: OpenSSL's code; an
# Ed25519 key to log in), running a command and in a terminal. Its pre-login program is the one seccomp_check picks, as
# the app does (QEMU can't apply seccomp filters, so the ARM build is checked without them); sshd's helpers are found
# at /usr/local/openssh/libexec, here commands that run the build's own (with QEMU, for the ARM build).
#
# $1 arch The architecture (amd64 or armhf)
check_openssh() {
    local arch="$1"
    local out=${BUILD_PATH}/${arch}/out
    local test=${BUILD_PATH}/${arch}/login
    local helpers=libexec-nosandbox
    local program
    local result
    local tries=0

    for program in ${out}/bin/* ${out}/libexec/* ${out}/libexec-nosandbox/*; do
        file "${program}" | grep -q "statically linked\|static-pie linked" || { echo "Not static: ${program}"; exit 1; }

        if grep -aq 'libnss_' "${program}"; then
            echo "Looks users up through NSS: ${program}"

            exit 1
        fi
    done

    run_for ${arch} ${out}/bin/sshd -V 2>&1 | grep "OpenSSH_${OPENSSH_VERSION}"

    if run_for ${arch} ${out}/bin/seccomp_check; then
        helpers=libexec
    fi

    echo "Login check with ${helpers}/sshd-auth"
    rm -rf ${test} /usr/local/openssh
    mkdir -p ${test} /usr/local/openssh/libexec /var/empty
    id ${PRIVSEP_USER} > /dev/null 2>&1 || adduser -S -D -H -h /var/empty -s /sbin/nologin ${PRIVSEP_USER}
    # (root has no password here: not locked, so a key login is allowed)
    sed -i 's/^root:[^:]*:/root:*:/' /etc/shadow

    for program in sshd-session sshd-auth; do
        if [ "${arch}" = armhf ]; then
            printf '#!/bin/sh\nexec qemu-arm -cpu cortex-a9 %s "$@"\n' "${out}/$([ ${program} = sshd-auth ] \
                && echo ${helpers} || echo libexec)/${program}" > /usr/local/openssh/libexec/${program}
        else
            printf '#!/bin/sh\nexec %s "$@"\n' "${out}/$([ ${program} = sshd-auth ] \
                && echo ${helpers} || echo libexec)/${program}" > /usr/local/openssh/libexec/${program}
        fi
        chmod 755 /usr/local/openssh/libexec/${program}
    done

    run_for ${arch} ${out}/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f ${test}/host_key
    run_for ${arch} ${out}/bin/ssh-keygen -q -t ed25519 -N '' -f ${test}/client_key
    cp ${test}/client_key.pub ${test}/authorized_keys
    cat > ${test}/sshd_config <<EOF2
Port 2222
ListenAddress 127.0.0.1
HostKey ${test}/host_key
PidFile ${test}/sshd.pid
AuthorizedKeysFile ${test}/authorized_keys
StrictModes no
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF2
    run_for ${arch} ${out}/bin/sshd -f ${test}/sshd_config -E ${test}/sshd.log

    until result="$(run_for ${arch} ${out}/bin/ssh -F /dev/null -i ${test}/client_key -p 2222 \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=rsa-sha2-512 \
        root@127.0.0.1 'echo login-ok' 2>&1)" && [ "${result##*$'\n'}" = login-ok ]; do
        tries=$((tries + 1))

        if [ ${tries} -ge 10 ]; then
            echo "${result}"
            cat ${test}/sshd.log
            echo "The ${arch} build's login check failed"

            exit 1
        fi

        sleep 2
    done

    # An interactive session's terminal too (configure can't check how to open one when cross-compiling)
    result="$(run_for ${arch} ${out}/bin/ssh -tt -F /dev/null -i ${test}/client_key -p 2222 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 'tty' 2>&1 < /dev/null || true)"

    if ! echo "${result}" | grep -q '^/dev/pts/'; then
        echo "${result}"
        cat ${test}/sshd.log
        echo "The ${arch} build's terminal check failed"

        exit 1
    fi

    echo "Login check passed (${arch})"
    kill "$(cat ${test}/sshd.pid)"
    rm -rf /usr/local/openssh
}

rm -rf ${BUILD_PATH}
mkdir -p ${BUILD_PATH}

fetch "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" openssh.tar.gz ${SHA256}
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    openssl.tar.gz ${OPENSSL_SHA256}
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" zlib.tar.gz \
    ${ZLIB_SHA256}
make_tools
build_arm_libraries

for arch in ${ARCHES}; do
    build_openssh ${arch}
    check_openssh ${arch}

    output=/data/packages/static/openssh/${VERSION}/${arch}
    rm -rf ${output}
    mkdir -p ${output}
    cp -a ${BUILD_PATH}/${arch}/out/. ${output}/
done

# Create a latest release file for ease of use in packages
printf '%s' "${VERSION}" > /data/packages/static/openssh/latest
chown -R "${HOST_IDS:-1000:1000}" /data/packages
