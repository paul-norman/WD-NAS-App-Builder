#!/bin/bash

# Prepares Navidrome for the NAS - for the Intel models and the ARM ones: its official static program for each, plus
# fully static builds of what it needs alongside it:
#  - ffmpeg:          for transcoding (e.g. to Opus or MP3 for phones) - built for audio only, with libopus and LAME,
#                     so it's small and depends on nothing (the NAS has no ffmpeg)
#  - navidrome_runas: switches to Navidrome's own user (the NAS has no su or similar) before running it. With --pty it
#                     runs the program in a pseudo-terminal fed from its input: Navidrome only reads new passwords from
#                     a terminal, and this keeps them off the command line

# The Intel build's tools use gcc. The ARM ones are cross-compiled on this (Intel) machine with Zig for the ARM models'
# ARMv7 processors (hard-float, NEON), and every ARM program - Navidrome's own included - is checked for their kernels'
# large memory pages (ci/check_arm_pages.py) and run with QEMU's emulator: Navidrome's version, ffmpeg making an Opus
# and an MP3 file, and the helper.

set -e
set -o pipefail
set -x

VERSION=0.64.2
# Each architecture's release, as its navidrome_checksums.txt gives it
NAVIDROME_SHA256=fdd87fd107818667c2c50bc24dc6ce856962c795b3822a91f95c066cfad2c53e
NAVIDROME_ARMHF_SHA256=1fa5d85196d2420c21ad91bbe811706a285390808c052cec56e3f54d9c9314c3
# Ffmpeg publishes GPG signatures: this download's was checked against its release key
# FCF986EA15E6E293A5644F10B4322F04D67658D8
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
# Its SHA1 matches SourceForge's: e3630adf399d8917d4da19b96937b7f9b12774ea
LAME_VERSION=4.0
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
# The architectures built (each into packages/static/navidrome/<version>/<arch>)
ARCHES='amd64 armhf'
ARM_HOST=arm-linux-musleabihf

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools

# Writes the ARM compiler's commands (Zig's): arm-cc, arm-ar and arm-ranlib. arm-cc leaves out the processor options
# ffmpeg's configure adds (-mcpu=cortex-a9, -march=...): Zig names processors its own way, and its own -mcpu already
# names the ARM models' kind.
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    cat > ${TOOLS_PATH}/arm-cc <<SH
#!/bin/sh
for arg in "\$@"; do
    shift

    case "\${arg}" in
        -mcpu=*|-march=*) continue ;;
    esac

    set -- "\$@" "\${arg}"
done

exec zig cc -target ${ARM_HOST} -mcpu=cortex_a9 "\$@"
SH
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/*
}

# Downloads every source into ${BUILD_PATH}, each checked against its SHA256.
function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/navidrome/navidrome/releases/download/v${VERSION}/navidrome_${VERSION}_linux_amd64.tar.gz" \
        navidrome-amd64.tar.gz ${NAVIDROME_SHA256}
    sh /data/static/fetch.sh \
        "https://github.com/navidrome/navidrome/releases/download/v${VERSION}/navidrome_${VERSION}_linux_armv7.tar.gz" \
        navidrome-armhf.tar.gz ${NAVIDROME_ARMHF_SHA256}
    sh /data/static/fetch.sh "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" opus.tar.gz \
        ${OPUS_SHA256}
    sh /data/static/fetch.sh \
        "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" lame.tar.gz \
        ${LAME_SHA256}
    # (Debian's and Alpine's copies of the very same file, if ffmpeg.org is down)
    sh /data/static/fetch.sh "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz \
        ${FFMPEG_SHA256} \
        "https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_${FFMPEG_VERSION}.orig.tar.xz" \
        "https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-${FFMPEG_VERSION}.tar.xz"
}

# Sets up the build for an architecture (the variables every step below uses): its compilers, where its libraries go
# (DEPS), and configure's options for it (HOST_OPTIONS).
#
# $1 arch The architecture (amd64 or armhf)
function use_arch() {
    ARCH="$1"
    SRC=${BUILD_PATH}/${ARCH}
    DEPS=${SRC}/deps
    mkdir -p ${SRC}

    if [ "${ARCH}" = armhf ]; then
        export CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib
        HOST_OPTIONS="--build=x86_64-alpine-linux-musl --host=${ARM_HOST}"
        STRIP=arm-none-eabi-strip
    else
        export CC=gcc AR=ar RANLIB=ranlib
        HOST_OPTIONS=''
        STRIP=strip
    fi
}

function build_opus() {
    cd ${SRC}
    tar -xzf ${BUILD_PATH}/opus.tar.gz
    cd opus-${OPUS_VERSION}
    ./configure ${HOST_OPTIONS} --prefix=${DEPS} --disable-shared --enable-static --disable-doc \
        --disable-extra-programs
    make -j "$(nproc)"
    make install
}

function build_lame() {
    cd ${SRC}
    tar -xzf ${BUILD_PATH}/lame.tar.gz
    cd lame-${LAME_VERSION}
    ./configure ${HOST_OPTIONS} --prefix=${DEPS} --disable-shared --enable-static --disable-frontend \
        --disable-gtktest --disable-decoder
    make -j "$(nproc)"
    make install
}

function build_ffmpeg() {
    local cross=()

    if [ "${ARCH}" = armhf ]; then
        cross=(--enable-cross-compile --arch=arm --cpu=cortex-a9 --target-os=linux --cc=${CC} --ar=${AR}
            --ranlib=${RANLIB} --nm=arm-none-eabi-nm --strip=${STRIP})
    fi

    cd ${SRC}
    tar -xJf ${BUILD_PATH}/ffmpeg.tar.xz
    cd ffmpeg-${FFMPEG_VERSION}
    # Only audio: reading the common music formats (and their cover art, copied as it is), writing what Navidrome
    # transcodes to (Opus, MP3, AAC, FLAC, WAV)
    PKG_CONFIG_PATH=${DEPS}/lib/pkgconfig ./configure "${cross[@]}" --prefix=${SRC}/ffmpeg-out \
        --pkg-config-flags=--static --extra-cflags="-I${DEPS}/include" --extra-ldflags="-L${DEPS}/lib -static" \
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
}

function build_runas() {
    cd ${SRC}
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
    ${CC} -O2 -static -o navidrome_runas navidrome_runas.c
}

# Puts the architecture's programs together in ${SRC}/package (Navidrome's own release for it, and the tools built
# here, stripped).
function assemble() {
    local package=${SRC}/package

    mkdir -p ${package} ${SRC}/navidrome
    tar -xzf ${BUILD_PATH}/navidrome-${ARCH}.tar.gz -C ${SRC}/navidrome
    cp ${SRC}/navidrome/navidrome ${SRC}/navidrome_runas ${SRC}/ffmpeg-out/bin/ffmpeg ${SRC}/ffmpeg-out/bin/ffprobe \
        ${package}/
    ${STRIP} ${package}/navidrome_runas ${package}/ffmpeg ${package}/ffprobe
}

# Checks the architecture's programs in ${SRC}/package: static (the ARM ones laid out for large memory pages), and
# working - Navidrome's version, ffmpeg making an Opus and an MP3 file from a WAV one (and ffprobe reading it), the
# helper - the ARM ones with QEMU.
function check() {
    local package=${SRC}/package
    local emulator=''
    local program usage format

    for program in navidrome navidrome_runas ffmpeg ffprobe; do
        if ! file ${package}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${ARCH}) isn't static: $(file ${package}/${program})"

            exit 1
        fi
    done

    if [ "${ARCH}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${package}
        emulator='qemu-arm -cpu cortex-a9'
    fi

    ${emulator} ${package}/navidrome --version > ${SRC}/version.txt
    grep "^${VERSION} " ${SRC}/version.txt > /dev/null
    # (no arguments: it says how to use it, and fails - showing that it runs)
    usage="$(${emulator} ${package}/navidrome_runas 2>&1 || true)"
    echo "${usage}" | grep 'Usage: navidrome_runas' > /dev/null

    # A second of a tone, as a WAV file, made into each format Navidrome transcodes to most
    rm -rf /tmp/nd-test
    mkdir -p /tmp/nd-test
    python3 -c "
import math, struct, wave
with wave.open('/tmp/nd-test/tone.wav', 'wb') as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(48000)
    out.writeframes(b''.join(struct.pack('<hh', int(8000 * math.sin(i / 10)), 0) for i in range(48000)))
"

    for format in opus:libopus mp3:libmp3lame; do
        ${emulator} ${package}/ffmpeg -hide_banner -loglevel error -i /tmp/nd-test/tone.wav -c:a ${format#*:} \
            -b:a 128k /tmp/nd-test/tone.${format%%:*}
        [ "$(stat -c %s /tmp/nd-test/tone.${format%%:*})" -gt 5000 ]
        ${emulator} ${package}/ffprobe -v error -show_entries format=duration -of csv=p=0 \
            /tmp/nd-test/tone.${format%%:*} | grep '^1\.0' > /dev/null
    done
}

function run() {
    local arch output

    # Clean start
    rm -rf ${BUILD_PATH}
    mkdir -p ${BUILD_PATH}

    download
    make_tools

    for arch in ${ARCHES}; do
        use_arch ${arch}
        build_opus
        build_lame
        build_ffmpeg
        build_runas
        assemble
        check

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/navidrome/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p $(dirname ${output})
        cp -r ${SRC}/package ${output}
        du -sh ${output}/*
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/navidrome/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
