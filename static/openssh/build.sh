#!/bin/sh

# Prepares OpenSSH for the NAS (its release, checked against its SHA256 - also signed by OpenSSH's release key), fully
# static (musl, with OpenSSL's libcrypto for RSA keys - the NAS's host key and most users' keys - and zlib):
#  - sshd, sshd-session, sshd-auth: the server - the listener and the per-connection programs it runs (from libexec)
#  - sftp-server:                   SFTP (WD's sshd_config names /usr/bin/sftp-server, which the app links to it)
#  - ssh, sftp, ssh-keygen:         the app's own checks (a trial login with a throwaway key before switching) and
#                                    the page's (fingerprints of the keys added)
#  - seccomp_check:                  whether the NAS's kernel can run OpenSSH's seccomp sandbox. Since 10.4 sshd stops
#                                    when it can't, and WD's kernel doesn't say whether it has seccomp filters, so the
#                                    pre-login program (sshd-auth, the only one with the sandbox) is built twice:
#                                    libexec (seccomp sandbox) and libexec-nosandbox (no system call filter - privilege separation still applies:
#                                    the pre-login part runs as its own user, shut in /var/empty), chosen at every start.
#                                    (OpenSSH's rlimit sandbox isn't an option: its configure check fails on musl)
# It's built for /usr/local/openssh, a link to the app's binaries made at every start (where sshd finds its helpers),
# with its own unprivileged user for privilege separation: WD's "sshd" user is the login user, with root's ID

set -e
set -x

# The app's version, and OpenSSH's (10.6p1 = OpenSSH 10.6, portable release 1)
VERSION=10.6.1
OPENSSH_VERSION=10.6p1
SHA256=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39
PRIVSEP_USER=sshpriv

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/openssh/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

rm -rf ${BUILD_PATH}
mkdir -p ${BUILD_PATH}

fetch "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" openssh.tar.gz ${SHA256}
tar -xzf openssh.tar.gz
cd openssh-${OPENSSH_VERSION}
# No PAM, utmp, wtmp or lastlog: WD's sshd uses none - passwords are checked against /etc/shadow - and musl's login
# records are stubs (the pre-login program without a sandbox first, then everything with the seccomp sandbox)
configure() {
    ./configure --prefix=/usr/local/openssh --libexecdir=/usr/local/openssh/libexec --sysconfdir=/etc/ssh \
    --with-privsep-user=${PRIVSEP_USER} --with-privsep-path=/var/empty --with-pid-dir=/var/run \
    --without-pam --disable-utmp --disable-wtmp --disable-lastlog --disable-utmpx --disable-wtmpx \
    --with-sandbox=$1 --with-ldflags=-static
}
configure no
make -j "$(nproc)" sshd-auth
mkdir -p ${BUILD_PATH}/out/bin ${BUILD_PATH}/out/libexec ${BUILD_PATH}/out/libexec-nosandbox
cp sshd-auth ${BUILD_PATH}/out/libexec-nosandbox/
make distclean
configure seccomp_filter
make -j "$(nproc)" sshd sshd-session sshd-auth sftp-server ssh sftp ssh-keygen

for program in sshd ssh sftp ssh-keygen; do
    cp ${program} ${BUILD_PATH}/out/bin/
done

for program in sshd-session sshd-auth sftp-server; do
    cp ${program} ${BUILD_PATH}/out/libexec/
done

# seccomp_check: exits 0 when a seccomp filter (allowing everything) can be applied, as OpenSSH's sandbox applies its
# own
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
gcc -O2 -static -o ${BUILD_PATH}/out/bin/seccomp_check seccomp_check.c
strip ${BUILD_PATH}/out/bin/* ${BUILD_PATH}/out/libexec/* ${BUILD_PATH}/out/libexec-nosandbox/*

# Every program fully static, and none that looks users up through NSS (musl has none)
for program in ${BUILD_PATH}/out/bin/* ${BUILD_PATH}/out/libexec/* ${BUILD_PATH}/out/libexec-nosandbox/*; do
    file "${program}" | grep -q "statically linked\|static-pie linked" || { echo "Not static: ${program}"; exit 1; }

    if grep -aq 'libnss_' "${program}"; then
        echo "Looks users up through NSS: ${program}"

        exit 1
    fi
done

${BUILD_PATH}/out/bin/sshd -V 2>&1 | grep "OpenSSH_${OPENSSH_VERSION}"

rm -rf ${OUTPUT_PATH}
mkdir -p ${OUTPUT_PATH}
cp -a ${BUILD_PATH}/out/bin ${BUILD_PATH}/out/libexec ${BUILD_PATH}/out/libexec-nosandbox ${OUTPUT_PATH}/
cp LICENCE ${OUTPUT_PATH}/LICENCE
