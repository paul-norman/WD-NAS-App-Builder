#!/bin/bash

# Prepares Music Assistant for the NAS: its own Python (a portable, relocatable build of the version it needs) with
# Music Assistant and its packages installed into it, plus:
#  - ffmpeg / ffprobe: fully static (built in the Dockerfile), for decoding, resampling and streaming to the players
#  - ma_runas:        switches to Music Assistant's own user (the NAS has no su or similar) before running it
#
# Left out: the on-device audio analysis packages (PyTorch and friends, gigabytes) - Music Assistant only uses them on
# CPUs with AVX2, which no WD NAS has, and turns those features off by itself without them. Also left out: the WebRTC
# library for its optional remote access (installed from a development branch, so not yet released), and the AirPlay
# sender (its program needs a newer glibc than the NAS's)

set -e
set -o pipefail
set -x

VERSION=2.10.9
MA_WHEEL_SHA256=3115b9ce54de8ded623e0285abd7de4cd5c02a0091a544b895cc460c3697c52b
# Music Assistant's list of every package its features use, from the same release
MA_REQUIREMENTS_SHA256=769b2bd3a26d38062a3a8a884cdca0569eb6d37bfdb891dc3eec015dda680435
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
# Packages not installed (see above)
EXCLUDED='torch|torchaudio|torchlibrosa|librosa|transformers|huggingface-hub|nnAudio|beat-this|kaldi-native-fbank|usearch|numkong|aiolibdatachannel|yappi'
# The newest glibc / libstdc++ symbol versions the NAS has (OS5: glibc 2.31, GLIBCXX 3.4.28)
NAS_GLIBC=2.31

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
PYTHON_PATH=${BUILD_PATH}/python
OUTPUT_PATH=/data/packages/static/music-assistant/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    wget -q "$1" -O "$2"
    echo "$3  $2" | sha256sum -c -
}

function build_python() {
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz
    # uv installs the packages (Music Assistant also uses it itself, for packages a feature needs)
    ${PYTHON_PATH}/bin/python3 -m pip install --quiet --root-user-action=ignore uv
}

function build_music_assistant() {
    fetch "https://raw.githubusercontent.com/music-assistant/server/${VERSION}/requirements_all.txt" requirements_all.txt ${MA_REQUIREMENTS_SHA256}
    grep -vE "^(--extra-index-url|${EXCLUDED})" requirements_all.txt | grep -vE '^(#|$)' > requirements.txt
    # Urllib3-future must not take over urllib3's name - as in Music Assistant's own image
    URLLIB3_NO_OVERRIDE=1 ${PYTHON_PATH}/bin/python3 -m uv pip install --python ${PYTHON_PATH}/bin/python3 \
        --break-system-packages --no-binary urllib3-future -r requirements.txt
    fetch "https://github.com/music-assistant/server/releases/download/${VERSION}/music_assistant-${VERSION}-py3-none-any.whl" \
        music_assistant-${VERSION}-py3-none-any.whl ${MA_WHEEL_SHA256}
    # Without its dependencies: they're all installed above, minus the excluded ones
    ${PYTHON_PATH}/bin/python3 -m uv pip install --python ${PYTHON_PATH}/bin/python3 --break-system-packages --no-deps \
        ${BUILD_PATH}/music_assistant-${VERSION}-py3-none-any.whl
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
    cat > ma_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: ma_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("ma_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("ma_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o ma_runas ma_runas.c
    strip ma_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_python
    build_music_assistant
    build_runas

    # Not needed by a server: the terminal database (for interactive programs), whose folders differ only in case -
    # which a case-insensitive file system (e.g. a Windows drive holding the repository) can't store. Nothing else may
    rm -rf ${PYTHON_PATH}/share/terminfo

    if [ -n "$(find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${PYTHON_PATH} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${PYTHON_PATH} ${OUTPUT_PATH}/python
    cp ${BUILD_PATH}/ma_runas /opt/ffmpeg /opt/ffprobe ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/python/bin/python3 -c "import music_assistant, aiosonos, soco, ytmusicapi, zeroconf, av; print('Music Assistant imports')"
    ${OUTPUT_PATH}/ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt && head -n 1 ${BUILD_PATH}/ffmpeg-version.txt
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages
}

run
