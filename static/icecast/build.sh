#!/bin/bash

# Prepares Icecast for the NAS - every program fully static (musl), so nothing depends on the NAS's own libraries:
#  - icecast:   the streaming server (with its web pages and admin pages, in share/icecast)
#  - ezstream:  streams a playlist to Icecast, so the NAS can broadcast a folder of music by itself
#  - ffmpeg:    turns each track ezstream plays into the stream's format (MP3) - built for audio only, with LAME
#  - ice_runas: switches to Icecast's own user (the NAS has no su or similar) before running it
# Built from source, with the libraries Alpine has no static versions of: libigloo, RHash and libshout (Xiph's), TagLib
# (ezstream reads the tracks' titles with it)

set -e
set -o pipefail
set -x

VERSION=2.5.0
ICECAST_SHA256=d9aa07c7429aec19d950ff6fd425c371f77158cd34ff220fc191b2c186c67c7a
EZSTREAM_VERSION=1.0.2
EZSTREAM_SHA256=11de897f455a95ba58546bdcd40a95d3bda69866ec5f7879a83b024126c54c2a
IGLOO_VERSION=0.9.5
IGLOO_SHA256=ea22e9119f7a2188810f99100c5155c6762d4595ae213b9ac29e69b4f0b87289
RHASH_VERSION=1.4.6
RHASH_SHA256=9f6019cfeeae8ace7067ad22da4e4f857bb2cfa6c2deaa2258f55b2227ec937a
SHOUT_VERSION=2.4.6
SHOUT_SHA256=39cbd4f0efdfddc9755d88217e47f8f2d7108fa767f9d58a2ba26a16d8f7c910
TAGLIB_VERSION=2.3.2
TAGLIB_SHA256=3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
# LAME's matches SourceForge's SHA1 e3630adf399d8917d4da19b96937b7f9b12774ea
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
OUT=${BUILD_PATH}/out
OUTPUT_PATH=/data/packages/static/icecast/${VERSION}/${ARCH}
export PKG_CONFIG_PATH=${DEPS_PATH}/lib/pkgconfig:${DEPS_PATH}/lib64/pkgconfig
export CPPFLAGS="-I${DEPS_PATH}/include"
export LDFLAGS="-L${DEPS_PATH}/lib -L${DEPS_PATH}/lib64"
# Every library's own libraries too, for static linking
export PKG_CONFIG='pkg-config --static'

# Downloads a file and checks it against its SHA256, then unpacks it
function fetch() {
    cd ${BUILD_PATH}
    wget -q "$1" -O "$2"
    echo "$3  $2" | sha256sum -c -
    tar -xf "$2"
}

function build_libraries() {
    # Libigloo needs RHash
    fetch "https://github.com/rhash/RHash/archive/refs/tags/v${RHASH_VERSION}.tar.gz" rhash.tar.gz ${RHASH_SHA256}
    cd RHash-${RHASH_VERSION}
    ./configure --prefix=${DEPS_PATH} --enable-lib-static --disable-lib-shared --disable-openssl --disable-gettext
    make -j "$(nproc)" lib-static
    make install-lib-static install-lib-headers

    fetch "https://downloads.xiph.org/releases/igloo/libigloo-${IGLOO_VERSION}.tar.gz" igloo.tar.gz ${IGLOO_SHA256}
    cd libigloo-${IGLOO_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static LIBS='-lrhash'
    make -j "$(nproc)"
    make install

    fetch "https://downloads.xiph.org/releases/libshout/libshout-${SHOUT_VERSION}.tar.gz" shout.tar.gz ${SHOUT_SHA256}
    cd libshout-${SHOUT_VERSION}
    # Title updates (Icecast's /admin/metadata) first ask without the password, and libshout never asks again after
    # Icecast's 401: they're sent with it straight away (its "source" state), as curl or other clients would
    sed -i 's/^    shout_connection_set_nonblocking(connection, SHOUT_BLOCKING_FULL);$/&\n    if (self->protocol == SHOUT_PROTOCOL_HTTP)\n        connection->current_protocol_state = 1;/' src/icy.c
    grep -q 'connection->current_protocol_state = 1;' src/icy.c
    # Without TLS, two of its files use free() and snprintf() without including their headers - an error for newer
    # compilers
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --disable-theora --disable-speex --disable-tls \
        CFLAGS='-O2 -include stdlib.h -include stdio.h'
    make -j "$(nproc)"
    make install

    fetch "https://taglib.org/releases/taglib-${TAGLIB_VERSION}.tar.gz" taglib.tar.gz ${TAGLIB_SHA256}
    cmake -S taglib-${TAGLIB_VERSION} -B taglib-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${DEPS_PATH} \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_BINDINGS=ON -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF
    cmake --build taglib-build -j "$(nproc)"
    cmake --install taglib-build

    fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" lame.tar.gz ${LAME_SHA256}
    cd lame-${LAME_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder
    make -j "$(nproc)"
    make install
}

function build_icecast() {
    fetch "https://downloads.xiph.org/releases/icecast/icecast-${VERSION}.tar.gz" icecast.tar.gz ${ICECAST_SHA256}
    cd icecast-${VERSION}
    # Without TLS and the public directory listing: the Nginx app serves it over HTTPS, and no curl is needed
    ./configure --prefix=/opt/icecast --disable-yp --without-openssl --without-curl --without-speex --without-theora \
        LDFLAGS="${LDFLAGS} -static" LIBS='-lrhash -lm'
    # Its own target for a static program: libtool links programs statically only with -all-static
    make -j "$(nproc)" static
    make install DESTDIR=${OUT}
}

function build_ezstream() {
    fetch "https://downloads.xiph.org/releases/ezstream/ezstream-${EZSTREAM_VERSION}.tar.gz" ezstream.tar.gz ${EZSTREAM_SHA256}
    cd ezstream-${EZSTREAM_VERSION}
    # Libshout 2.4.6 only accepts MP3 streams marked as audio; ezstream 1.0.2 predates that
    sed -i 's/SHOUT_FORMAT_MP3, 0, NULL/SHOUT_FORMAT_MP3, SHOUT_USAGE_AUDIO, NULL/' src/stream.c
    grep -q 'SHOUT_FORMAT_MP3, SHOUT_USAGE_AUDIO' src/stream.c
    # TagLib is C++: its C bindings need the C++ library too. It uses basename() as glibc declares it in string.h; musl
    # declares it in libgen.h
    ./configure --prefix=/opt/ezstream --disable-shared --with-taglib=${DEPS_PATH} --with-libshout=${DEPS_PATH} \
        CFLAGS='-O2 -include libgen.h' LDFLAGS="${LDFLAGS} -static" LIBS='-ltag -lstdc++ -lvorbis -logg -lz -lm'
    # Libtool links programs statically only with -all-static
    make -j "$(nproc)" LDFLAGS="${LDFLAGS} -all-static"
    cp src/ezstream ${OUT}/ezstream
    file ${OUT}/ezstream
}

function build_ffmpeg() {
    fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz ${FFMPEG_SHA256}
    cd ffmpeg-${FFMPEG_VERSION}
    # Audio only: the usual music formats in, raw audio out (ezstream's decoder); raw audio in, MP3 out (its encoder)
    # (ffmpeg reads its standard input - "-" - through the fd protocol)
    ./configure --pkg-config-flags=--static --extra-ldflags='-static' --disable-everything --disable-doc --disable-debug \
        --disable-ffplay --disable-ffprobe --disable-autodetect --disable-network --disable-avdevice --disable-swscale \
        --enable-static --disable-shared --enable-libmp3lame \
        --enable-protocol=file,pipe,fd \
        --enable-demuxer=aac,aiff,ape,asf,dsf,flac,matroska,mov,mp3,mpc,mpc8,ogg,wav,wv,tak,pcm_s16le \
        --enable-decoder=aac,aac_latm,alac,ape,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,flac,mp1,mp2,mp3,mp3float,mpc7,mpc8,opus,tak,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_u8 \
        --enable-encoder=libmp3lame,pcm_s16le \
        --enable-muxer=mp3,pcm_s16le \
        --enable-parser=aac,flac,mpegaudio,opus,vorbis \
        --enable-filter=aresample,aformat,anull,volume,loudnorm
    make -j "$(nproc)"
    strip ffmpeg
    cp ffmpeg ${OUT}/ffmpeg
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > ice_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: ice_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("ice_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("ice_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o ${OUT}/ice_runas ice_runas.c
}

function run() {
    rm -rf ${BUILD_PATH}
    mkdir -p ${BUILD_PATH} ${OUT}

    build_libraries
    build_icecast
    build_ezstream
    build_ffmpeg
    build_runas

    # Checked before anything is copied out: a failed build leaves no output, which would count as built
    for program in opt/icecast/bin/icecast ezstream ffmpeg ice_runas; do
        if file ${OUT}/${program} | grep -q dynamic; then
            echo "${program} isn't static"

            exit 1
        fi
    done

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp ${OUT}/opt/icecast/bin/icecast ${OUT}/ezstream ${OUT}/ffmpeg ${OUT}/ice_runas ${OUTPUT_PATH}/
    strip ${OUTPUT_PATH}/icecast ${OUTPUT_PATH}/ezstream ${OUTPUT_PATH}/ice_runas
    # Its web pages and admin pages (the configuration points to them)
    mkdir -p ${OUTPUT_PATH}/share
    cp -r ${OUT}/opt/icecast/share/icecast ${OUTPUT_PATH}/share/
    rm -rf ${OUTPUT_PATH}/share/icecast/doc
    ${OUTPUT_PATH}/icecast -v
    ${OUTPUT_PATH}/ezstream -V
    ${OUTPUT_PATH}/ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt && head -n 1 ${BUILD_PATH}/ffmpeg-version.txt
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
