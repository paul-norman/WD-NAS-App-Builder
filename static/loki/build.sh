#!/bin/bash

# Prepares the logs app for the NAS: Grafana Loki (stores the logs) and Vector (reads the log files and sends them to
# Loki) - both official static programs - plus a fully static build of:
#  - loki_runas: switches to Loki's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=3.7.9
LOKI_SHA256=17a5fae28ce733b3560c27c76620920b169bd2aea9473947b733b511f92e81dd
VECTOR_VERSION=0.60.0
VECTOR_SHA256=9584f402e67fea7ff2dd846f0a8bbb56fa32951bded11749093ff3780e1513cf

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/loki/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
	cd ${BUILD_PATH}
	wget -q "$1" -O "$2"
	echo "$3  $2" | sha256sum -c -
}

function build_runas() {
	cd ${BUILD_PATH}
	cat > loki_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: loki_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("loki_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("loki_runas: could not run the program");
	return 127;
}
C
	gcc -O2 -static -o loki_runas loki_runas.c
	strip loki_runas
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	fetch "https://github.com/grafana/loki/releases/download/v${VERSION}/loki-linux-amd64.zip" loki.zip ${LOKI_SHA256}
	unzip -q loki.zip
	fetch "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-x86_64-unknown-linux-musl.tar.gz" vector.tar.gz ${VECTOR_SHA256}
	tar -xzf vector.tar.gz
	build_runas

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}
	cp ${BUILD_PATH}/loki-linux-amd64 ${OUTPUT_PATH}/loki
	cp ${BUILD_PATH}/vector-x86_64-unknown-linux-musl/bin/vector ${BUILD_PATH}/loki_runas ${OUTPUT_PATH}/
	chmod 755 ${OUTPUT_PATH}/loki
	${OUTPUT_PATH}/loki --version | head -n 1
	${OUTPUT_PATH}/vector --version
	du -sh ${OUTPUT_PATH}

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
