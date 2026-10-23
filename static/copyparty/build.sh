#!/bin/bash

# Prepares CopyParty for the NAS: its own Python (a portable, relocatable build) with CopyParty and the packages its
# features use installed into it, plus:
#  - Pillow (+ pillow-heif): thumbnails of pictures, including iPhones' HEIC photos
#  - mutagen:                music tags (artist, album... - searchable, and shown in its music player)
#  - argon2-cffi:            hashed passwords
#  - paramiko:               its SFTP server (optional, off unless turned on)
#  - ffmpeg / ffprobe:       fully static (built in the Dockerfile): thumbnails of videos and audio, transcoding for its
#                            music player
#  - cpp_runas:              switches to CopyParty's own user (the NAS has no su or similar) before running it
#
# Left out: FTP (pyftpdlib) - it sends passwords unencrypted - and SMB (impacket, which CopyParty itself advises against)

set -e
set -o pipefail
set -x

VERSION=1.20.26
# (PyPI's checksum of CopyParty's wheel)
CPP_WHEEL_SHA256=7e51a2576699c089fe6ad74dfd59db02575eb4211af8870372b10a63caf611cb
CPP_PACKAGES="argon2-cffi pillow pillow-heif mutagen paramiko"
PYTHON_VERSION=3.14.9
PYTHON_RELEASE=20261021
PYTHON_SHA256=561e91c1cadf30e84aec94d1917384ae3267e5f3e6e135e51fd1578bb19f4064
UV_VERSION=0.13.4
UV_SHA256=28d4385f9f9d1d1c7654d85b3855e0e2615b2f6cc13136a2edff858bbdc16ff1
# The newest glibc symbol version the NAS has (OS5: glibc 2.31)
NAS_GLIBC=2.31

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
PYTHON_PATH=${BUILD_PATH}/python
OUTPUT_PATH=/data/packages/static/copyparty/${VERSION}/${ARCH}
# CopyParty's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/copyparty/requirements.txt

# Downloads a file and checks it against its SHA256
function fetch() {
	cd ${BUILD_PATH}
	wget -q "$1" -O "$2"
	echo "$3  $2" | sha256sum -c -
}

function build_copyparty() {
	fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
		python.tar.gz ${PYTHON_SHA256}
	tar -xzf python.tar.gz
	fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" uv.tar.gz ${UV_SHA256}
	tar -xzf uv.tar.gz
	local uv=${BUILD_PATH}/uv-x86_64-unknown-linux-musl/uv
	if [ ! -f ${LOCK} ]; then
		{ echo "copyparty==${VERSION}"; echo "${CPP_PACKAGES}" | tr ' ' '\n'; } > requirements.in
		${uv} pip compile --quiet --python ${PYTHON_PATH}/bin/python3 --generate-hashes --no-header requirements.in -o ${LOCK}
	fi
	# (the lock must hold CopyParty's own published checksum)
	grep -q "${CPP_WHEEL_SHA256}" ${LOCK}
	${uv} pip install --python ${PYTHON_PATH}/bin/python3 --break-system-packages --require-hashes -r ${LOCK}
	# Not needed on the NAS: pip (packages come with the app)
	${uv} pip uninstall --python ${PYTHON_PATH}/bin/python3 --break-system-packages pip
	# Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
	${PYTHON_PATH}/bin/python3 -m compileall -q ${PYTHON_PATH}/lib/python3.14/site-packages > /dev/null || true

	# Every compiled part must run with the NAS's glibc
	local found=0
	while read -r file; do
		head -c 4 "${file}" | grep -q ELF || continue
		for version in $(objdump -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
			if [ "${version#GLIBC_2.}" -gt "${NAS_GLIBC#2.}" ]; then
				echo "${file} needs ${version}"
				found=1
			fi
		done
	done < <(find ${PYTHON_PATH} -type f \( -name '*.so*' -o -perm -u+x \))
	if [ ${found} = 1 ]; then
		echo "Something needs a newer glibc than the NAS's (${NAS_GLIBC})"
		exit 1
	fi
}

function build_runas() {
	cd ${BUILD_PATH}
	cat > cpp_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program. Files it creates are
// writable by the group too (umask 002), as the NAS's shares expect
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: cpp_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("cpp_runas: could not switch user");
		return 1;
	}
	umask(002);
	execv(argv[3], &argv[3]);
	perror("cpp_runas: could not run the program");
	return 127;
}
C
	gcc -O2 -static -o cpp_runas cpp_runas.c
	strip cpp_runas
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_copyparty
	build_runas

	# Not needed by a server: the terminal database (for interactive programs), whose folders differ only in case -
	# which a case-insensitive file system (e.g. a Windows drive holding the repository) can't store. Nothing else may
	rm -rf ${PYTHON_PATH}/share/terminfo
	if [ -n "$(find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
		find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
		echo "These paths differ only in case"
		exit 1
	fi

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}
	cp -a ${PYTHON_PATH} ${OUTPUT_PATH}/python
	cp ${BUILD_PATH}/cpp_runas /opt/ffmpeg /opt/ffprobe ${OUTPUT_PATH}/
	${OUTPUT_PATH}/python/bin/python3 -c "import copyparty, argon2, PIL, pillow_heif, mutagen, paramiko; print('CopyParty imports')"
	${OUTPUT_PATH}/python/bin/python3 -m copyparty --version
	${OUTPUT_PATH}/ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt && head -n 1 ${BUILD_PATH}/ffmpeg-version.txt
	du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/*

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages /data/static/copyparty/requirements.txt;
}

run
