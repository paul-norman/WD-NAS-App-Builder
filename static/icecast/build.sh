#!/bin/bash

# Prepares Icecast for the NAS - for the Intel models and the ARM ones, every program fully static (musl), so nothing
# depends on the NAS's own libraries:
#  - icecast:   the streaming server (with its web pages and admin pages, in share/icecast)
#  - ezstream:  streams a playlist to Icecast, so the NAS can broadcast a folder of music by itself
#  - ffmpeg:    turns each track ezstream plays into the stream's format (MP3) - built for audio only, with LAME
#  - ice_runas: switches to Icecast's own user (the NAS has no su or similar) before running it
# Built from source, with the libraries Alpine has no static versions of: libigloo, RHash and libshout (Xiph's), TagLib
# (ezstream reads the tracks' titles with it), LAME

# The Intel build uses gcc and Alpine's static libraries. The ARM one is cross-compiled on this (Intel) machine with
# clang, linked by LLD (which lays programs out for the ARM models' large memory pages - 32KB on the EX2 Ultra), against
# Alpine's own static ARM libraries (the Alpine ARM system in /armv7, from the Dockerfile), with the libraries above
# built into it; configure's test programs run with QEMU's emulator. Each build is checked: every program static (the
# ARM ones' layout too: ci/check_arm_pages.py), ffmpeg making an MP3, and Icecast started, serving its status page (the
# ARM ones with QEMU).

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
# The architectures built (each into packages/static/icecast/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools
# The ARM build: clang's target, and the Alpine ARM system (its libraries built here go in its /usr/local)
TARGET=armv7-alpine-linux-musleabihf
SYSROOT=/armv7

# Writes the ARM cross-compiling tools: cc and c++ (clang for the ARM models, against the Alpine ARM system, linked by
# LLD), each turning a test program it links (conftest) into a script running it with QEMU; pkg-config (the Alpine ARM
# system's libraries, with what their static libraries need); a CMake toolchain file.
function make_tools() {
    local compiler

    mkdir -p ${TOOLS_PATH}

    for compiler in cc:clang c++:clang++; do
        {
            echo '#!/bin/sh'
            echo "out=''"
            echo "previous=''"
            echo 'for arg in "$@"; do'
            echo '    [ "${previous}" = -o ] && out="${arg}"'
            echo '    previous="${arg}"'
            echo 'done'
            echo "${compiler#*:} --target=${TARGET} --sysroot=${SYSROOT} -mcpu=cortex-a9 -fuse-ld=lld -Qunused-arguments \"\$@\" || exit \$?"
            echo 'case "${out}" in'
            echo '    conftest|*/conftest)'
            echo '        mv "${out}" "${out}.arm"'
            echo "        printf '#!/bin/sh\\nexec qemu-arm -cpu cortex-a9 %s \"\$@\"\\n' \"\$(cd \"\$(dirname \"\${out}\")\" && pwd)/\$(basename \"\${out}\").arm\" > \"\${out}\""
            echo '        chmod 755 "${out}"'
            echo '        ;;'
            echo 'esac'
        } > ${TOOLS_PATH}/${compiler%%:*}
    done

    {
        echo '#!/bin/sh'
        echo "export PKG_CONFIG_SYSROOT_DIR=${SYSROOT}"
        echo "export PKG_CONFIG_LIBDIR=${SYSROOT}/usr/local/lib/pkgconfig:${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
        echo 'exec /usr/bin/pkg-config --static "$@"'
    } > ${TOOLS_PATH}/pkg-config
    chmod 755 ${TOOLS_PATH}/cc ${TOOLS_PATH}/c++ ${TOOLS_PATH}/pkg-config

    {
        echo 'set(CMAKE_SYSTEM_NAME Linux)'
        echo 'set(CMAKE_SYSTEM_PROCESSOR arm)'
        echo "set(CMAKE_C_COMPILER ${TOOLS_PATH}/cc)"
        echo "set(CMAKE_CXX_COMPILER ${TOOLS_PATH}/c++)"
        echo "set(CMAKE_AR /usr/bin/arm-none-eabi-ar CACHE FILEPATH \"\")"
        echo "set(CMAKE_RANLIB /usr/bin/arm-none-eabi-ranlib CACHE FILEPATH \"\")"
        echo "set(CMAKE_SYSROOT ${SYSROOT})"
        echo "set(CMAKE_FIND_ROOT_PATH ${SYSROOT})"
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)'
        echo 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)'
        echo "set(PKG_CONFIG_EXECUTABLE ${TOOLS_PATH}/pkg-config)"
    } > ${TOOLS_PATH}/arm.cmake
}

# Sets up the build for an architecture (the variables every step below uses): its compilers and tools, where its
# libraries go (PREFIX, installed under DESTDIR), and configure's options for it (HOST_OPTIONS).
#
# $1 arch The architecture (amd64 or armhf)
function use_arch() {
    ARCH="$1"
    OUT=${BUILD_PATH}/${ARCH}/out
    SRC=${BUILD_PATH}/${ARCH}
    mkdir -p ${OUT}

    if [ "${ARCH}" = armhf ]; then
        PREFIX=/usr/local
        DESTDIR=${SYSROOT}
        export CC=${TOOLS_PATH}/cc CXX=${TOOLS_PATH}/c++ AR=arm-none-eabi-ar RANLIB=arm-none-eabi-ranlib
        export PKG_CONFIG=${TOOLS_PATH}/pkg-config
        export CPPFLAGS=''
        export LDFLAGS="-L${SYSROOT}${PREFIX}/lib"
        unset PKG_CONFIG_PATH
        HOST_OPTIONS="--build=x86_64-alpine-linux-musl --host=${TARGET}"
        CMAKE_OPTIONS="-DCMAKE_TOOLCHAIN_FILE=${TOOLS_PATH}/arm.cmake"
        STRIP=arm-none-eabi-strip
        # Where ezstream finds TagLib and libshout
        LIBS_ROOT=${SYSROOT}${PREFIX}
    else
        PREFIX=${BUILD_PATH}/amd64/deps
        DESTDIR=''
        export CC=gcc CXX=g++ AR=ar RANLIB=ranlib
        # Every library's own libraries too, for static linking
        export PKG_CONFIG='pkg-config --static'
        export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig
        export CPPFLAGS="-I${PREFIX}/include"
        export LDFLAGS="-L${PREFIX}/lib -L${PREFIX}/lib64"
        HOST_OPTIONS=''
        CMAKE_OPTIONS=''
        STRIP=strip
        LIBS_ROOT=${PREFIX}
    fi
}

# Downloads every source into ${BUILD_PATH}, each checked against its SHA256.
function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://github.com/rhash/RHash/archive/refs/tags/v${RHASH_VERSION}.tar.gz" rhash.tar.gz \
        ${RHASH_SHA256}
    sh /data/static/fetch.sh "https://downloads.xiph.org/releases/igloo/libigloo-${IGLOO_VERSION}.tar.gz" igloo.tar.gz \
        ${IGLOO_SHA256}
    sh /data/static/fetch.sh "https://downloads.xiph.org/releases/libshout/libshout-${SHOUT_VERSION}.tar.gz" \
        shout.tar.gz ${SHOUT_SHA256}
    sh /data/static/fetch.sh "https://taglib.org/releases/taglib-${TAGLIB_VERSION}.tar.gz" taglib.tar.gz \
        ${TAGLIB_SHA256}
    sh /data/static/fetch.sh \
        "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" lame.tar.gz \
        ${LAME_SHA256}
    sh /data/static/fetch.sh "https://downloads.xiph.org/releases/icecast/icecast-${VERSION}.tar.gz" icecast.tar.gz \
        ${ICECAST_SHA256}
    sh /data/static/fetch.sh "https://downloads.xiph.org/releases/ezstream/ezstream-${EZSTREAM_VERSION}.tar.gz" \
        ezstream.tar.gz ${EZSTREAM_SHA256}
    # (Debian's and Alpine's copies of the very same file, if ffmpeg.org is down)
    sh /data/static/fetch.sh "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz \
        ${FFMPEG_SHA256} \
        "https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_${FFMPEG_VERSION}.orig.tar.xz" \
        "https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-${FFMPEG_VERSION}.tar.xz"
}

# Unpacks a source archive from ${BUILD_PATH} into the architecture's folder, and goes into it.
#
# $1 archive The archive's name
# $2 folder  The folder it unpacks to
function unpack() {
    cd ${SRC}
    tar -xf ${BUILD_PATH}/$1
    cd $2
}

function build_libraries() {
    # Libigloo needs RHash
    unpack rhash.tar.gz RHash-${RHASH_VERSION}

    if [ "${ARCH}" = armhf ]; then
        ./configure --prefix=${PREFIX} --enable-lib-static --disable-lib-shared --disable-openssl --disable-gettext \
            --cc=${CC} --ar=${AR} --target=arm-linux
    else
        ./configure --prefix=${PREFIX} --enable-lib-static --disable-lib-shared --disable-openssl --disable-gettext
    fi

    make -j "$(nproc)" lib-static
    make install-lib-static install-lib-headers DESTDIR=${DESTDIR}

    unpack igloo.tar.gz libigloo-${IGLOO_VERSION}
    ./configure ${HOST_OPTIONS} --prefix=${PREFIX} --disable-shared --enable-static LIBS='-lrhash'
    make -j "$(nproc)"
    make install DESTDIR=${DESTDIR}

    unpack shout.tar.gz libshout-${SHOUT_VERSION}
    # Title updates (Icecast's /admin/metadata) first ask without the password, and libshout never asks again after
    # Icecast's 401: they're sent with it straight away (its "source" state), as curl or other clients would
    sed -i 's/^    shout_connection_set_nonblocking(connection, SHOUT_BLOCKING_FULL);$/&\n    if (self->protocol == SHOUT_PROTOCOL_HTTP)\n        connection->current_protocol_state = 1;/' src/icy.c
    grep -q 'connection->current_protocol_state = 1;' src/icy.c
    # Without TLS, two of its files use free() and snprintf() without including their headers - an error for newer
    # compilers
    ./configure ${HOST_OPTIONS} --prefix=${PREFIX} --disable-shared --enable-static --disable-theora --disable-speex \
        --disable-tls CFLAGS='-O2 -include stdlib.h -include stdio.h'
    make -j "$(nproc)"
    make install DESTDIR=${DESTDIR}

    cd ${SRC}
    tar -xf ${BUILD_PATH}/taglib.tar.gz
    cmake -S taglib-${TAGLIB_VERSION} -B taglib-build ${CMAKE_OPTIONS} -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_BINDINGS=ON \
        -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF
    cmake --build taglib-build -j "$(nproc)"
    DESTDIR=${DESTDIR} cmake --install taglib-build

    unpack lame.tar.gz lame-${LAME_VERSION}
    ./configure ${HOST_OPTIONS} --prefix=${PREFIX} --disable-shared --enable-static --disable-frontend \
        --disable-gtktest --disable-decoder
    make -j "$(nproc)"
    make install DESTDIR=${DESTDIR}
}

function build_icecast() {
    unpack icecast.tar.gz icecast-${VERSION}
    # Without TLS and the public directory listing: the Nginx app serves it over HTTPS, and no curl is needed
    ./configure ${HOST_OPTIONS} --prefix=/opt/icecast --disable-yp --without-openssl --without-curl --without-speex \
        --without-theora LDFLAGS="${LDFLAGS} -static" LIBS='-lrhash -lm'
    # Its own target for a static program: libtool links programs statically only with -all-static
    make -j "$(nproc)" static
    make install DESTDIR=${OUT}
}

function build_ezstream() {
    unpack ezstream.tar.gz ezstream-${EZSTREAM_VERSION}
    # Libshout 2.4.6 only accepts MP3 streams marked as audio; ezstream 1.0.2 predates that
    sed -i 's/SHOUT_FORMAT_MP3, 0, NULL/SHOUT_FORMAT_MP3, SHOUT_USAGE_AUDIO, NULL/' src/stream.c
    grep -q 'SHOUT_FORMAT_MP3, SHOUT_USAGE_AUDIO' src/stream.c
    # TagLib is C++: its C bindings need the C++ library too. It uses basename() as glibc declares it in string.h; musl
    # declares it in libgen.h
    ./configure ${HOST_OPTIONS} --prefix=/opt/ezstream --disable-shared --with-taglib=${LIBS_ROOT} \
        --with-libshout=${LIBS_ROOT} CFLAGS='-O2 -include libgen.h' LDFLAGS="${LDFLAGS} -static" \
        LIBS='-ltag -lstdc++ -lvorbis -logg -lz -lm'
    # Libtool links programs statically only with -all-static
    make -j "$(nproc)" LDFLAGS="${LDFLAGS} -all-static"
    cp src/ezstream ${OUT}/ezstream
    file ${OUT}/ezstream
}

function build_ffmpeg() {
    local cross=()

    if [ "${ARCH}" = armhf ]; then
        cross=(--enable-cross-compile --arch=arm --cpu=cortex-a9 --target-os=linux --cc=${CC} --cxx=${CXX}
            --ar=${AR} --ranlib=${RANLIB} --nm=arm-none-eabi-nm --strip=${STRIP} --pkg-config=${PKG_CONFIG})
    fi

    unpack ffmpeg.tar.xz ffmpeg-${FFMPEG_VERSION}
    # Audio only: the usual music formats in, raw audio out (ezstream's decoder); raw audio in, MP3 out (its encoder)
    # (ffmpeg reads its standard input - "-" - through the fd protocol)
    ./configure "${cross[@]}" --pkg-config-flags=--static --extra-ldflags='-static' --disable-everything --disable-doc \
        --disable-debug --disable-ffplay --disable-ffprobe --disable-autodetect --disable-network --disable-avdevice \
        --disable-swscale --enable-static --disable-shared --enable-libmp3lame \
        --enable-protocol=file,pipe,fd \
        --enable-demuxer=aac,aiff,ape,asf,dsf,flac,matroska,mov,mp3,mpc,mpc8,ogg,wav,wv,tak,pcm_s16le \
        --enable-decoder=aac,aac_latm,alac,ape,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,flac,mp1,mp2,mp3,mp3float,mpc7,mpc8,opus,tak,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_u8 \
        --enable-encoder=libmp3lame,pcm_s16le \
        --enable-muxer=mp3,pcm_s16le \
        --enable-parser=aac,flac,mpegaudio,opus,vorbis \
        --enable-filter=aresample,aformat,anull,volume,loudnorm
    make -j "$(nproc)"
    cp ffmpeg ${OUT}/ffmpeg
}

function build_runas() {
    cd ${SRC}
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
    ${CC} -O2 -static -o ${OUT}/ice_runas ice_runas.c
}

# Puts the architecture's programs, and Icecast's web pages and admin pages (its configuration points to them),
# together in ${SRC}/package, stripped.
function assemble() {
    local package=${SRC}/package

    mkdir -p ${package}/share
    cp ${OUT}/opt/icecast/bin/icecast ${OUT}/ezstream ${OUT}/ffmpeg ${OUT}/ice_runas ${package}/
    ${STRIP} ${package}/icecast ${package}/ezstream ${package}/ffmpeg ${package}/ice_runas
    cp -r ${OUT}/opt/icecast/share/icecast ${package}/share/
    rm -rf ${package}/share/icecast/doc
}

# Checks the architecture's programs in ${SRC}/package: static (the ARM ones laid out for large memory pages), their
# versions, ffmpeg turning a WAV file into an MP3, and Icecast started (as nobody, by ice_runas) serving its status
# page - the ARM ones with QEMU.
function check() {
    local package=${SRC}/package
    local emulator='' port=18000
    # (what ice_runas runs: under QEMU, an ARM program can only start another through QEMU - which is this machine's)
    local server=${package}/icecast
    local program pid i

    for program in icecast ezstream ffmpeg ice_runas; do
        if ! file ${package}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${ARCH}) isn't static: $(file ${package}/${program})"

            exit 1
        fi
    done

    if [ "${ARCH}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${package}/icecast ${package}/ezstream ${package}/ffmpeg \
            ${package}/ice_runas
        emulator='qemu-arm -cpu cortex-a9'
        server="/usr/bin/qemu-arm -cpu cortex-a9 ${package}/icecast"
        port=18001
    fi

    ${emulator} ${package}/icecast -v | grep "Icecast ${VERSION}" > /dev/null
    ${emulator} ${package}/ezstream -V | grep "${EZSTREAM_VERSION}" > /dev/null
    ${emulator} ${package}/ffmpeg -hide_banner -version > ${SRC}/ffmpeg-version.txt
    grep "ffmpeg version ${FFMPEG_VERSION}" ${SRC}/ffmpeg-version.txt > /dev/null

    rm -rf /tmp/ice-test
    mkdir -p /tmp/ice-test/log
    # A second of a tone, as a WAV file, made into an MP3
    python3 -c "
import math, struct, wave
with wave.open('/tmp/ice-test/tone.wav', 'wb') as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(44100)
    out.writeframes(b''.join(struct.pack('<h', int(8000 * math.sin(i / 10))) for i in range(44100)))
"
    ${emulator} ${package}/ffmpeg -hide_banner -loglevel error -i /tmp/ice-test/tone.wav -c:a libmp3lame -b:a 128k \
        -f mp3 /tmp/ice-test/tone.mp3
    [ "$(stat -c %s /tmp/ice-test/tone.mp3)" -gt 10000 ]

    cat > /tmp/ice-test/icecast.xml <<XML
<icecast>
    <hostname>localhost</hostname>
    <authentication>
        <source-password>source-check</source-password>
        <admin-user>admin</admin-user>
        <admin-password>admin-check</admin-password>
    </authentication>
    <listen-socket>
        <port>${port}</port>
        <bind-address>127.0.0.1</bind-address>
    </listen-socket>
    <paths>
        <logdir>/tmp/ice-test/log</logdir>
        <webroot>${package}/share/icecast/web</webroot>
        <adminroot>${package}/share/icecast/admin</adminroot>
    </paths>
    <logging>
        <errorlog>error.log</errorlog>
        <accesslog>access.log</accesslog>
        <loglevel>information</loglevel>
    </logging>
</icecast>
XML
    chown -R 65534:65534 /tmp/ice-test
    chmod 600 /tmp/ice-test/icecast.xml
    # (started directly, so that it's the process stopped afterwards)
    ${emulator} ${package}/ice_runas 65534 65534 ${server} -c /tmp/ice-test/icecast.xml \
        > /tmp/ice-test/icecast.out 2>&1 &
    pid=$!

    for i in $(seq 1 60); do
        wget -q -O /tmp/ice-test/status.json http://127.0.0.1:${port}/status-json.xsl 2>/dev/null && break
        sleep 1
    done

    kill ${pid} 2>/dev/null || true
    wait ${pid} 2>/dev/null || true

    # (its status page made by its XSLT stylesheet - libxslt working)
    if ! grep '"icestats":{' /tmp/ice-test/status.json > /dev/null \
        || ! grep '"server_start_iso8601":' /tmp/ice-test/status.json > /dev/null; then
        echo "Icecast (${ARCH}) didn't serve its status page:"
        cat /tmp/ice-test/status.json /tmp/ice-test/log/access.log /tmp/ice-test/icecast.out \
            /tmp/ice-test/log/error.log 2>/dev/null

        exit 1
    fi
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
        build_libraries
        build_icecast
        build_ezstream
        build_ffmpeg
        build_runas
        assemble
        check

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=/data/packages/static/icecast/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p $(dirname ${output})
        cp -r ${SRC}/package ${output}
        du -sh ${output} ${output}/*
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/icecast/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
