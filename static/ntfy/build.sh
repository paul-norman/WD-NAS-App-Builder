#!/bin/bash

# Prepares ntfy for the NAS: its official static program, plus a fully static build of:
#  - ntfy_runas: switches to ntfy's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=2.32.0
NTFY_SHA256=681819773a69079c0efdd64c096cc2149d9290243feb3e31dd3ef04a2c85f1ed

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/ntfy/${VERSION}/${ARCH}

function build_ntfy() {
	cd ${BUILD_PATH}
	wget -q "https://github.com/binwiederhier/ntfy/releases/download/v${VERSION}/ntfy_${VERSION}_linux_amd64.tar.gz" -O ntfy.tar.gz
	echo "${NTFY_SHA256}  ntfy.tar.gz" | sha256sum -c -
	tar -xzf ntfy.tar.gz
}

function build_runas() {
	cd ${BUILD_PATH}
	cat > ntfy_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: ntfy_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("ntfy_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("ntfy_runas: could not run the program");
	return 127;
}
C
	gcc -O2 -static -o ntfy_runas ntfy_runas.c
	strip ntfy_runas
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_ntfy
	build_runas

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}
	cp ${BUILD_PATH}/ntfy_${VERSION}_linux_amd64/ntfy ${BUILD_PATH}/ntfy_runas ${OUTPUT_PATH}/
	${OUTPUT_PATH}/ntfy --help > /dev/null
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
