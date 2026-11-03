#!/bin/bash

# Prepares Prometheus for the NAS: its official static program (stripped of debugging symbols - promtool is left out, as
# Prometheus checks its configuration itself, keeping the old one if a new one is broken), plus a fully static build of:
#  - prom_runas: switches to Prometheus' own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=3.15.1
PROMETHEUS_SHA256=6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/prometheus/${VERSION}/${ARCH}

function build_prometheus() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/prometheus/prometheus/releases/download/v${VERSION}/prometheus-${VERSION}.linux-amd64.tar.gz" \
        prometheus.tar.gz "${PROMETHEUS_SHA256}"
    tar -xzf prometheus.tar.gz
    strip prometheus-${VERSION}.linux-amd64/prometheus
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > prom_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: prom_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("prom_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("prom_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o prom_runas prom_runas.c
    strip prom_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_prometheus
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/prometheus-${VERSION}.linux-amd64/prometheus ${BUILD_PATH}/prom_runas ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/prometheus --version
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
