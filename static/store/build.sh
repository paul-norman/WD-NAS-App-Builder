#!/bin/bash

# Prepares the Store's signature checker for the NAS - for the Intel models and the ARM ones. A fully static build of:
#  - store_verify: checks a catalogue's Ed25519 signature with Monocypher (checked against the SHA256 pinned here).
#    Without it, a NAS whose PHP has no sodium and whose OpenSSL is older than 3 (WD's own PHP and OpenSSL 1.1, on every
#    model) can't check signatures at all, unless the PHP app is installed - and it's for the Intel models only.

# The ARM models' build is made on this (Intel) machine: cross-compiled with Zig for their ARMv7 processors (hard-float),
# and checked with QEMU's emulator.

set -e
set -o pipefail
set -x

# Monocypher's version
VERSION=4.0.2
MONOCYPHER_SHA256=38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c
# The architectures built (each into packages/static/store/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

# Compiles a fully static C program for an architecture (stripped): gcc for amd64, Zig for armhf.
#
# $1 arch The architecture (amd64 or armhf)
# $@      The compiler's other arguments
function cc_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s "$@"
    else
        gcc -O2 -static -s "$@"
    fi
}

# Runs a program built for an architecture here (an ARM one with QEMU's emulator, as a Cortex-A9 - the ARM models'
# processors' kind).
#
# $1 arch The architecture (amd64 or armhf)
# $@      The program and its arguments
function run_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 "$@"
    else
        "$@"
    fi
}

# Downloads and unpacks Monocypher into ${BUILD_PATH}/monocypher.
function fetch_monocypher() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://monocypher.org/download/monocypher-${VERSION}.tar.gz" monocypher.tar.gz \
        "${MONOCYPHER_SHA256}"
    tar -xzf monocypher.tar.gz
    mv "monocypher-${VERSION}" monocypher

    cat > store_verify.c <<'C'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "monocypher-ed25519.h"

// Reads a whole file (at most 64MB) into memory: the size in *size, NULL if it can't
static uint8_t *read_file(const char *path, size_t *size) {
	FILE *f = fopen(path, "rb");
	if (f == NULL) {
		return NULL;
	}
	size_t cap = 65536, len = 0;
	uint8_t *buf = malloc(cap);
	while (buf != NULL) {
		size_t n = fread(buf + len, 1, cap - len, f);
		len += n;
		if (len < cap) {
			break;
		}
		if (cap >= 64u << 20) {
			free(buf);
			buf = NULL;
			break;
		}
		uint8_t *bigger = realloc(buf, cap * 2);
		if (bigger == NULL) {
			free(buf);
		}
		buf = bigger;
		cap *= 2;
	}
	if (buf != NULL && ferror(f)) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	*size = len;
	return buf;
}

// Checks an Ed25519 signature (RFC 8032): exits 0 if it's valid, 1 if it isn't, 2 if it couldn't check it
int main(int argc, char **argv) {
	uint8_t key[32];
	if (argc != 4 || strlen(argv[1]) != 64) {
		fprintf(stderr, "Usage: store_verify <key, 64 hex digits> <signature file, 64 bytes> <data file>\n");
		return 2;
	}
	for (int i = 0; i < 32; i++) {
		unsigned int byte;
		if (sscanf(argv[1] + 2 * i, "%2x", &byte) != 1) {
			fprintf(stderr, "store_verify: the key isn't hex\n");
			return 2;
		}
		key[i] = (uint8_t)byte;
	}
	size_t sig_size, data_size;
	uint8_t *sig = read_file(argv[2], &sig_size);
	uint8_t *data = read_file(argv[3], &data_size);
	if (sig == NULL || data == NULL) {
		fprintf(stderr, "store_verify: could not read the signature or the data\n");
		return 2;
	}
	if (sig_size != 64) {
		return 1;
	}
	return crypto_ed25519_check(sig, key, data, data_size) == 0 ? 0 : 1;
}
C
}

# Builds the signature checker for an architecture in the current folder, and checks it with RFC 8032's first test
# vector (an empty message): valid, and refused with a changed message or signature.
#
# $1 arch The architecture (amd64 or armhf)
function build_verify() {
    local arch="$1" src=${BUILD_PATH}/monocypher/src
    local key=d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
    local sig=e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b

    cc_for "${arch}" -I${src} -I${src}/optional -o store_verify ${BUILD_PATH}/store_verify.c ${src}/monocypher.c \
        ${src}/optional/monocypher-ed25519.c

    printf "$(printf '%s' "${sig}" | sed 's/../\\x&/g')" > sig.bin
    : > empty
    printf 'x' > changed
    run_for "${arch}" ./store_verify "${key}" sig.bin empty

    if run_for "${arch}" ./store_verify "${key}" sig.bin changed; then
        echo 'store_verify accepted a changed message' >&2

        exit 1
    fi

    printf "$(printf '%s' "${sig/#e5/e6}" | sed 's/../\\x&/g')" > bad.bin

    if run_for "${arch}" ./store_verify "${key}" bad.bin empty; then
        echo 'store_verify accepted a changed signature' >&2

        exit 1
    fi
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}
    fetch_monocypher

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_verify ${arch}

        output=/data/packages/static/store/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp store_verify ${output}/
        cp ${BUILD_PATH}/monocypher/LICENCE.md ${output}/MONOCYPHER-LICENCE.md
        du -sh ${output}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/store/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
