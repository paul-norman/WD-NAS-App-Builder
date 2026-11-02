#!/bin/bash

# Prepares Navidrome for the NAS: its official static program, plus fully static builds of what it needs alongside it:
#  - ffmpeg:          for transcoding (e.g. to Opus or MP3 for phones) - built for audio only, with libopus and LAME,
#                     so it's small and depends on nothing (the NAS has no ffmpeg)
#  - navidrome_runas: switches to Navidrome's own user (the NAS has no su or similar) before running it. With --pty it
#                     runs the program in a pseudo-terminal fed from its input: Navidrome only reads new passwords from
#                     a terminal, and this keeps them off the command line

set -e
set -o pipefail
set -x

VERSION=0.64.2
NAVIDROME_SHA256=fdd87fd107818667c2c50bc24dc6ce856962c795b3822a91f95c066cfad2c53e
# Ffmpeg publishes GPG signatures: this download's was checked against its release key
# FCF986EA15E6E293A5644F10B4322F04D67658D8
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
# Its SHA1 matches SourceForge's: e3630adf399d8917d4da19b96937b7f9b12774ea
LAME_VERSION=4.0
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
DEPS_PATH=${BUILD_PATH}/deps
OUTPUT_PATH=/data/packages/static/navidrome/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    wget -q "$1" -O "$2"
    echo "$3  $2" | sha256sum -c -
}

function build_navidrome() {
    fetch "https://github.com/navidrome/navidrome/releases/download/v${VERSION}/navidrome_${VERSION}_linux_amd64.tar.gz" navidrome.tar.gz ${NAVIDROME_SHA256}
    mkdir -p navidrome
    tar -xzf navidrome.tar.gz -C navidrome
}

function build_opus() {
    fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" opus.tar.gz ${OPUS_SHA256}
    tar -xzf opus.tar.gz
    cd opus-${OPUS_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --disable-doc --disable-extra-programs
    make -j "$(nproc)"
    make install
}

function build_lame() {
    fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" lame.tar.gz ${LAME_SHA256}
    tar -xzf lame.tar.gz
    cd lame-${LAME_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder
    make -j "$(nproc)"
    make install
}

function build_ffmpeg() {
    fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz ${FFMPEG_SHA256}
    tar -xJf ffmpeg.tar.xz
    cd ffmpeg-${FFMPEG_VERSION}
    # Only audio: reading the common music formats (and their cover art, copied as it is), writing what Navidrome
    # transcodes to (Opus, MP3, AAC, FLAC, WAV)
    PKG_CONFIG_PATH=${DEPS_PATH}/lib/pkgconfig ./configure --prefix=${BUILD_PATH}/ffmpeg-out \
        --pkg-config-flags=--static --extra-cflags="-I${DEPS_PATH}/include" --extra-ldflags="-L${DEPS_PATH}/lib -static" \
        --disable-everything --disable-doc --disable-debug --disable-ffplay --disable-network --disable-autodetect \
        --disable-avdevice --disable-swscale --enable-static --disable-shared \
        --enable-libopus --enable-libmp3lame \
        --enable-protocol=file,pipe \
        --enable-demuxer=aac,aiff,ape,asf,dsf,flac,matroska,mov,mp3,mpc,mpc8,ogg,wav,wv,tak,image2,image2pipe \
        --enable-decoder=aac,aac_latm,alac,ape,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,flac,mp1,mp2,mp3,mp3float,mpc7,mpc8,opus,libopus,tak,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_u8 \
        --enable-encoder=libopus,libmp3lame,aac,flac,pcm_s16le \
        --enable-muxer=adts,flac,ipod,matroska,mp3,mp4,ogg,opus,wav,webm,image2,image2pipe \
        --enable-parser=aac,flac,mpegaudio,opus,vorbis,mjpeg,png \
        --enable-filter=aresample,aformat,anull,atrim,volume,loudnorm,amix,concat,null,copy,format,trim
    make -j "$(nproc)"
    make install
    strip ${BUILD_PATH}/ffmpeg-out/bin/ffmpeg ${BUILD_PATH}/ffmpeg-out/bin/ffprobe

    for program in ${BUILD_PATH}/ffmpeg-out/bin/ffmpeg ${BUILD_PATH}/ffmpeg-out/bin/ffprobe; do
        if ldd "${program}" 2>&1 | grep -q '=>'; then
            echo "${program} isn't static"

            exit 1
        fi
    done
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > navidrome_runas.c <<'C'
#include <errno.h>
#include <grp.h>
#include <pty.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program. With --pty, the
// program runs in a pseudo-terminal: everything on this program's input is typed into it, and its output is passed on
static void switch_user(const char *uid_text, const char *gid_text) {
	uid_t uid = (uid_t)strtoul(uid_text, NULL, 10);
	gid_t gid = (gid_t)strtoul(gid_text, NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("navidrome_runas: could not switch user");
		exit(1);
	}
}

int main(int argc, char **argv) {
	int pty = argc > 1 && strcmp(argv[1], "--pty") == 0;
	if (pty) {
		argv++;
		argc--;
	}
	if (argc < 4) {
		fprintf(stderr, "Usage: navidrome_runas [--pty] <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	if (!pty) {
		switch_user(argv[1], argv[2]);
		execv(argv[3], &argv[3]);
		perror("navidrome_runas: could not run the program");
		return 127;
	}

	// What's to be typed (e.g. a password, twice), read before starting the program
	char input[4096];
	size_t length = fread(input, 1, sizeof(input), stdin);
	int master;
	pid_t pid = forkpty(&master, NULL, NULL, NULL);
	if (pid < 0) {
		perror("navidrome_runas: could not open a pseudo-terminal");
		return 1;
	}
	if (pid == 0) {
		switch_user(argv[1], argv[2]);
		execv(argv[3], &argv[3]);
		perror("navidrome_runas: could not run the program");
		_exit(127);
	}
	if (length > 0 && write(master, input, length) < 0) {
		perror("navidrome_runas: could not type into the program");
	}
	memset(input, 0, sizeof(input));
	char buffer[4096];
	ssize_t got;
	while ((got = read(master, buffer, sizeof(buffer))) > 0 || (got < 0 && errno == EINTR)) {
		if (got > 0) {
			fwrite(buffer, 1, (size_t)got, stdout);
		}
	}
	int status;
	if (waitpid(pid, &status, 0) < 0) {
		return 1;
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
    gcc -O2 -static -o navidrome_runas navidrome_runas.c
    strip navidrome_runas
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_navidrome
    build_opus
    build_lame
    build_ffmpeg
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/navidrome/navidrome ${BUILD_PATH}/navidrome_runas ${BUILD_PATH}/ffmpeg-out/bin/ffmpeg \
        ${BUILD_PATH}/ffmpeg-out/bin/ffprobe ${OUTPUT_PATH}/
    ${OUTPUT_PATH}/navidrome --version
    ${OUTPUT_PATH}/ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'libopus|libmp3lame| aac '
    du -sh ${OUTPUT_PATH}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages
}

run
