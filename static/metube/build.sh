#!/bin/bash

# Prepares MeTube (a web interface for yt-dlp) for the NAS's Intel models: its own Python (a portable, relocatable
# build, python-build-standalone's) with MeTube's packages installed into it (from MeTube's own lock, uv.lock: each
# version with its files' checksums, wheels checked against the NAS's glibc - including Deno, which yt-dlp runs for
# YouTube), MeTube's web interface (built with Node.js), plus:
#  - ffmpeg and ffprobe, built here statically for what yt-dlp asks of them: joining video and audio, remuxing,
#    extracting audio (Opus, MP3, AAC), converting thumbnails - no network and no video encoders
#  - metube_runas: switches to MeTube's own user (the NAS has no su or similar) before running it
#
# Only for the Intel models: Deno and curl-cffi have no 32-bit ARM builds. (MeTube's Docker image also has bgutil-pot,
# for YouTube's "proof of origin" tokens - left out: its release needs glibc 2.34, the NAS has 2.31.) The build is
# checked by starting MeTube and having it download a test video from a local web server.

set -e
set -o pipefail
set -x

VERSION=2026.11.24
# MeTube's release has no source archive of its own: GitHub's archive of its tag, pinned here
METUBE_SHA256=e813f160bc1ac21980b56f38e81a1279ce060f3041e6ab3aa884748f4fdbafd6
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# Only builds the web interface (not in the package); pnpm as MeTube's package.json names it
NODE_VERSION=26.13.1
NODE_SHA256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
PNPM_VERSION=12.6.0
# ffmpeg and the encoders it's built with (as the Navidrome app's)
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
LAME_VERSION=4.0
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
# The newest glibc symbol version the NAS has (OS5's Intel models: glibc 2.31)
NAS_GLIBC=2.31

BUILD_PATH=/build
SRC=${BUILD_PATH}/src
DEPS=${BUILD_PATH}/deps
# Built here, then copied to OUTPUT once checked (build_static.sh takes an output folder that isn't empty as built)
STAGE=${BUILD_PATH}/out
OUTPUT=/data/packages/static/metube/${VERSION}/amd64

# Downloads a file into the current folder and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
# $4...     Other addresses with the very same file
function fetch() {
    sh /data/static/fetch.sh "$@"
}

# Downloads everything into ${BUILD_PATH}, and puts uv and Node.js (with pnpm) on the PATH.
function prepare() {
    cd ${BUILD_PATH}
    fetch "https://github.com/alexta69/metube/archive/refs/tags/${VERSION}.tar.gz" metube.tar.gz ${METUBE_SHA256}
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" opus.tar.gz ${OPUS_SHA256}
    fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" lame.tar.gz \
        ${LAME_SHA256}
    # (Debian's and Alpine's copies of the very same file, if ffmpeg.org is down)
    fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz ${FFMPEG_SHA256} \
        "https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_${FFMPEG_VERSION}.orig.tar.xz" \
        "https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-${FFMPEG_VERSION}.tar.xz"

    tar -xzf uv.tar.gz
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    export PATH="${BUILD_PATH}/node/bin:${BUILD_PATH}/uv-x86_64-unknown-linux-musl:${PATH}"
    npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}"

    tar -xzf metube.tar.gz
    mv metube-${VERSION} metube
}

# Builds Opus and LAME (static libraries) into ${DEPS}, then ffmpeg and ffprobe with them, into ${SRC}/ffmpeg-out.
function build_ffmpeg() {
    mkdir -p ${SRC}
    cd ${SRC}
    tar -xzf ${BUILD_PATH}/opus.tar.gz
    cd opus-${OPUS_VERSION}
    ./configure --prefix=${DEPS} --disable-shared --enable-static --disable-doc --disable-extra-programs
    make -j "$(nproc)"
    make install

    cd ${SRC}
    tar -xzf ${BUILD_PATH}/lame.tar.gz
    cd lame-${LAME_VERSION}
    ./configure --prefix=${DEPS} --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder
    make -j "$(nproc)"
    make install

    cd ${SRC}
    tar -xJf ${BUILD_PATH}/ffmpeg.tar.xz
    cd ffmpeg-${FFMPEG_VERSION}
    # What yt-dlp's post-processors use: joining and remuxing (streams copied as they are), audio extraction (Opus,
    # MP3, AAC, FLAC, WAV), thumbnails converted to JPEG (decoding WebP / PNG / JPEG, scaling), metadata and chapters,
    # every bitstream filter (yt-dlp names several: aac_adtstoasc, mjpeg2jpeg, setts...) -
    # local files only (yt-dlp downloads); and a test pattern input (lavfi: testsrc, sine), for the check
    PKG_CONFIG_PATH=${DEPS}/lib/pkgconfig ./configure --prefix=${SRC}/ffmpeg-out \
        --pkg-config-flags=--static --extra-cflags="-I${DEPS}/include" --extra-ldflags="-L${DEPS}/lib -static" \
        --disable-everything --disable-doc --disable-debug --disable-ffplay --disable-network --disable-autodetect \
        --enable-avdevice --enable-indev=lavfi --disable-x86asm --enable-static --disable-shared \
        --enable-libopus --enable-libmp3lame --enable-zlib \
        --enable-protocol=file,pipe,concat \
        --enable-demuxer=aac,ac3,concat,eac3,flac,flv,h264,hevc,hls,image2,image2pipe,jpeg_pipe,matroska,mov,mp3,mpegts,ogg,png_pipe,wav,webp_pipe,webvtt,srt,ffmetadata \
        --enable-decoder=wrapped_avframe,aac,aac_latm,ac3,eac3,flac,mp3,mp3float,opus,libopus,vorbis,pcm_s16le,pcm_s24le,pcm_f32le,mjpeg,png,webp,bmp,gif,webvtt,srt,subrip,mov_text,ass \
        --enable-encoder=aac,libopus,libmp3lame,flac,pcm_s16le,mjpeg,png,mov_text,webvtt,srt,subrip,ass \
        --enable-muxer=adts,ffmetadata,flac,image2,ipod,matroska,mjpeg,mov,mp3,mp4,mpegts,null,ogg,opus,wav,webm,webvtt,srt,ass \
        --enable-parser=aac,aac_latm,ac3,av1,flac,h264,hevc,mjpeg,mpegaudio,opus,png,vorbis,vp8,vp9,webp \
        --enable-bsfs \
        --enable-swscale \
        --enable-filter=aformat,anull,aresample,asetpts,atrim,concat,copy,crop,format,null,scale,setpts,setsar,trim,testsrc,sine
    make -j "$(nproc)"
    make install
}

# Builds MeTube's web interface (Angular), into metube/ui/dist/metube/browser.
function build_ui() {
    cd ${BUILD_PATH}/metube/ui
    CI=true pnpm install --frozen-lockfile
    pnpm run build
    [ -f dist/metube/browser/index.html ]
}

# Puts Python with MeTube's packages into ${STAGE}/python (keeping pip: the app updates yt-dlp with it), and MeTube
# itself (its code and built web interface) into ${STAGE}/metube.
function build_python() {
    local lib=${STAGE}/python/lib/python3.14

    cd ${STAGE}
    tar -xzf ${BUILD_PATH}/python.tar.gz

    cd ${BUILD_PATH}/metube
    uv export --frozen --no-dev --no-emit-project --format requirements-txt -o ${BUILD_PATH}/requirements.txt
    uv pip install --python ${STAGE}/python/bin/python3 --break-system-packages --only-binary :all: \
        --python-platform x86_64-manylinux_${NAS_GLIBC/./_} --require-hashes -r ${BUILD_PATH}/requirements.txt

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, and the terminal database - whose folders differ
    # only in case, which a Windows drive holding the repository can't store
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${STAGE}/python/lib/tcl* \
        ${STAGE}/python/lib/tk* ${STAGE}/python/lib/libtcl* ${STAGE}/python/lib/libtk* ${STAGE}/python/lib/itcl* \
        ${STAGE}/python/lib/thread* ${STAGE}/python/share/terminfo ${STAGE}/python/bin/idle3*
    rm -f ${lib}/lib-dynload/_tkinter*

    mkdir -p ${STAGE}/metube/ui/dist/metube
    cp -a app ${STAGE}/metube/
    rm -rf ${STAGE}/metube/app/tests
    cp -a ui/dist/metube/browser ${STAGE}/metube/ui/dist/metube/
    cp LICENSE ${STAGE}/metube/ 2>/dev/null || true
    printf '%s\n' "${VERSION}" > ${STAGE}/version

    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${STAGE}/python/bin/python3 -m compileall -q ${STAGE}/metube/app ${lib} > /dev/null || true
}

# Puts the programs MeTube runs into ${STAGE}/bin (the app puts it first on MeTube's PATH): ffmpeg and ffprobe; and
# builds the run-as helper.
function build_programs() {
    mkdir -p ${STAGE}/bin
    cp ${SRC}/ffmpeg-out/bin/ffmpeg ${SRC}/ffmpeg-out/bin/ffprobe ${STAGE}/bin/
    strip ${STAGE}/bin/ffmpeg ${STAGE}/bin/ffprobe

    cd ${BUILD_PATH}
    cat > metube_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Run by root: switches to the given user and group, with the given extra groups (a comma-separated list, or -), then
// runs the program
int main(int argc, char **argv) {
	if (argc < 5) {
		fprintf(stderr, "Usage: metube_runas <uid> <gid> <groups|-> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	gid_t groups[32];
	int count = 0;
	if (argv[3][0] != '-') {
		for (char *part = strtok(argv[3], ","); part && count < 32; part = strtok(NULL, ",")) {
			groups[count++] = (gid_t)strtoul(part, NULL, 10);
		}
	}
	if (setgroups(count, groups) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("metube_runas: could not switch user");
		return 1;
	}
	execv(argv[4], &argv[4]);
	perror("metube_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o ${STAGE}/metube_runas metube_runas.c
    rm metube_runas.c
}

# Checks that nothing needs a newer glibc than the NAS's.
function check_glibc() {
    local found=0
    local file version

    while read -r file; do
        head -c 4 "${file}" | grep -q ELF || continue

        for version in $(objdump -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${NAS_GLIBC#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(find ${STAGE} -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${NAS_GLIBC})"

        exit 1
    fi
}

# Checks the build: the programs run, and MeTube - started in a scratch folder - downloads a test video (made with
# this ffmpeg, served by a local web server) through its API, as the app's Watch page has it do.
function check() {
    local data=${BUILD_PATH}/check
    local python=${STAGE}/python/bin/python3
    local pid server attempt file result

    export PATH="${STAGE}/bin:${PATH}"
    ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt
    sed -n 1p ${BUILD_PATH}/ffmpeg-version.txt
    ${python} -m yt_dlp --version
    # (Deno: the JavaScript runtime yt-dlp runs YouTube's challenges with, from its Python package)
    "$(find ${STAGE}/python -type f -name deno -perm -u+x -print -quit)" --version
    ${python} -c 'import curl_cffi, aiohttp, socketio; print("curl_cffi", curl_cffi.__version__)'
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${STAGE}/metube_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: metube_runas'

    # yt-dlp's own post-processors with this ffmpeg (each names its filters): thumbnails (PNG, JPEG) to JPEG, as the
    # app has it do before each download, and the timestamp fix
    mkdir -p ${data}/thumbs
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=160x90 -frames:v 1 ${data}/thumbs/a.png
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=160x90 -frames:v 1 ${data}/thumbs/b.jpeg
    ${python} - ${data}/thumbs <<'PY'
import os
import sys

from yt_dlp import YoutubeDL
from yt_dlp.postprocessor.ffmpeg import FFmpegThumbnailsConvertorPP

folder = sys.argv[1]
converter = FFmpegThumbnailsConvertorPP(YoutubeDL({"quiet": True}))

for name in ("a.png", "b.jpeg"):
    converter.convert_thumbnail(os.path.join(folder, name), "jpg")

for name in ("a.jpg", "b.jpg"):
    assert os.path.getsize(os.path.join(folder, name)) > 0, name
PY
    for filter in aac_adtstoasc mjpeg2jpeg setts h264_mp4toannexb; do
        ffmpeg -hide_banner -bsfs > ${BUILD_PATH}/bsfs.txt
        grep -qx "${filter}" ${BUILD_PATH}/bsfs.txt
    done

    # A short test video (MJPEG and AAC in MP4: what this ffmpeg can make), served locally
    mkdir -p ${data}/www ${data}/downloads ${data}/state
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=3:size=320x240:rate=10 \
        -f lavfi -i sine=frequency=440:duration=3 -c:v mjpeg -c:a aac -shortest ${data}/www/test-clip.mp4
    ( cd ${data}/www && exec ${python} -m http.server 8999 --bind 127.0.0.1 ) > ${data}/http.log 2>&1 &
    server=$!

    ( cd ${STAGE}/metube && DOWNLOAD_DIR=${data}/downloads STATE_DIR=${data}/state TEMP_DIR=${data}/state \
        HOST=127.0.0.1 PORT=8085 ALLOW_PRIVATE_ADDRESSES=true exec ${python} app/main.py ) > ${data}/metube.log 2>&1 &
    pid=$!

    for attempt in $(seq 1 60); do
        curl -s -o /dev/null http://127.0.0.1:8085/version && break
        sleep 1
    done

    curl -s http://127.0.0.1:8085/version
    curl -s -H 'Content-Type: application/json' -d '{"url": "http://127.0.0.1:8999/test-clip.mp4",
        "download_type": "video", "quality": "best", "format": "mp4", "codec": "auto", "folder": "check"}' \
        http://127.0.0.1:8085/add
    file=''

    for attempt in $(seq 1 60); do
        file="$(find ${data}/downloads/check -name '*.mp4' -print -quit 2>/dev/null)"
        [ -n "${file}" ] && break
        sleep 1
    done

    kill ${pid} ${server} 2>/dev/null || true
    wait ${pid} ${server} 2>/dev/null || true

    if [ -z "${file}" ] || ! ffprobe -v error -show_entries format=duration -of csv=p=0 "${file}"; then
        cat ${data}/metube.log

        exit 1
    fi
}

function run() {
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    mkdir -p ${STAGE}

    prepare
    build_ffmpeg
    build_ui
    build_python
    build_programs
    check_glibc
    check

    rm -rf ${OUTPUT}
    mkdir -p ${OUTPUT}
    cp -a ${STAGE}/. ${OUTPUT}/
    du -sh ${OUTPUT}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/metube/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
