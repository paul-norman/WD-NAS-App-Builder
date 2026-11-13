#!/bin/bash

# Prepares Nextcloud for the NAS - for the Intel models (it runs on the PHP app's PHP, which is Intel-only):
#  - its release, checked against its published checksum and kept as it is (the app's build unpacks it into the package)
#  - nextcloud_runas: switches to Nextcloud's own user (the NAS has no su or similar) before running its web server, its
#    PHP and its console (occ) - none of them run as root

set -e
set -o pipefail
set -x

VERSION=35.0.3
# As Nextcloud publishes it (<file>.sha256)
NEXTCLOUD_SHA256=58401440ce81b7f8d445a8c2a8027572b616ef83592f96b121fd15ec8a1aed35

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/nextcloud/${VERSION}/amd64

function build_runas() {
    cd ${BUILD_PATH}
    cat > nextcloud_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program - its files writable by
// the group too (umask 002), as the NAS's shares expect (Nextcloud sets its own files' modes itself)
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: nextcloud_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("nextcloud_runas: could not switch user");
		return 1;
	}
	umask(002);
	execv(argv[3], &argv[3]);
	perror("nextcloud_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o nextcloud_runas nextcloud_runas.c
    # (no arguments: it says how to use it, and fails - showing that it runs)
    (./nextcloud_runas 2>&1 || true) | grep -q "Usage: nextcloud_runas"
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    sh /data/static/fetch.sh "https://download.nextcloud.com/server/releases/nextcloud-${VERSION}.tar.bz2" \
        nextcloud.tar.bz2 "${NEXTCLOUD_SHA256}"

    # It's this version (its version.php), and complete enough to run (occ, its console)
    tar -xjf nextcloud.tar.bz2 nextcloud/version.php nextcloud/occ
    grep -q "\$OC_VersionString = '${VERSION}';" nextcloud/version.php
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp nextcloud.tar.bz2 nextcloud_runas ${OUTPUT_PATH}/
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/nextcloud/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
