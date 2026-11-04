#!/bin/bash

# Prepares postgres_exporter for the NAS: its official static program (checked against the SHA256 its release publishes in
# sha256sums.txt, pinned here), plus a fully static build of:
#  - postgres_exporter_runas: switches to the exporter's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=0.20.1
EXPORTER_SHA256=89d4f7e7920cad48fdc3133f789556ef5253c330a9f5fdace3bdb6344c0a8b5a

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/postgres_exporter/${VERSION}/${ARCH}

function build_exporter() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}/postgres_exporter-${VERSION}.linux-amd64.tar.gz" \
        exporter.tar.gz "${EXPORTER_SHA256}"
    tar -xzf exporter.tar.gz
    mv "postgres_exporter-${VERSION}.linux-amd64/postgres_exporter" postgres_exporter
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > postgres_exporter_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: postgres_exporter_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("postgres_exporter_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("postgres_exporter_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o postgres_exporter_runas postgres_exporter_runas.c
    strip postgres_exporter_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_exporter
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/postgres_exporter ${BUILD_PATH}/postgres_exporter_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/postgres_exporter --version 2>&1 | head -n 1
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
