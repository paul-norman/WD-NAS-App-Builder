#!/bin/bash

# Prepares CopyParty for the NAS - for the Intel models and the ARM ones: its own Python (a portable, relocatable build,
# python-build-standalone's) with CopyParty and the packages its features use installed into it, plus:
#  - Pillow (+ pillow-heif): thumbnails of pictures, including iPhones' HEIC photos
#  - mutagen:                music tags (artist, album... - searchable, and shown in its music player)
#  - argon2-cffi:            hashed passwords
#  - paramiko:               its SFTP server (optional, off unless turned on - the Intel models only)
#  - ffmpeg / ffprobe:       fully static: thumbnails of videos and audio, transcoding for its music player
#  - cpp_runas:              switches to CopyParty's own user (the NAS has no su or similar) before running it
#
# Left out: FTP (pyftpdlib) - it sends passwords unencrypted - and SMB (impacket, which CopyParty itself advises
# against).
#
# Intel: the packages are PyPI's wheels (from static/copyparty/requirements.txt: each version with its files'
# checksums), and ffmpeg is built in the Dockerfile. ARM: the ARM models' kernels use large memory pages (32KB on the
# EX2 Ultra), and programs and libraries laid out for 4KB ones crash there - as python-build-standalone's python3.14 and
# PyPI's ARM wheels are. So everything compiled is built here with Zig for their ARMv7 processors: python3.14 is a small
# launcher calling libpython (as in the Python app); the packages with compiled parts (ARM_BUILT) are built from their
# source (checked against the lock's checksums) for glibc 2.17, with the libraries they use - libffi, libjpeg-turbo,
# libwebp, zlib, libde265 and libheif - built in; the rest are PyPI's pure Python wheels (checked the same way); and
# ffmpeg is built fully static (musl) as the Intel one is, with its libraries. No SFTP server there: it needs
# cryptography, bcrypt and PyNaCl (ARM_SKIPPED). Every ARM file is checked for that layout (ci/check_arm_pages.py), and
# run with QEMU's emulator - CopyParty itself serving a folder and a thumbnail.

set -e
set -o pipefail
set -x

VERSION=1.20.28
# PyPI's checksum of CopyParty's wheel
CPP_WHEEL_SHA256=f74a83ed11d2edb17efb8e9b50cde8f7b81d1eb77964fcea23f5d860885b923f
CPP_PACKAGES='argon2-cffi pillow pillow-heif mutagen paramiko'
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
# Each architecture's checksums, as python-build-standalone's SHA256SUMS publishes them
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# The ARM models' compiler (its release's checksum)
ZIG_VERSION=0.17.1
ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# The ARM models' ffmpeg and its libraries (the same ffmpeg, Opus and LAME as the Dockerfile's, for the Intel models -
# see static/copyparty/downloads). Opus's checksum is Xiph's, Vorbis's matches Xiph's, LAME's and soxr's match
# SourceForge's SHA1s (e3630adf399d8917d4da19b96937b7f9b12774ea, 32ea46b1a8c0c15f835422892d02fce8286aec3c); the GitHub
# releases' are as GitHub publishes them
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
LAME_VERSION=4.0
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
OGG_VERSION=1.3.6
OGG_SHA256=83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
VORBIS_VERSION=1.3.7
VORBIS_SHA256=b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
SOXR_VERSION=0.1.3
SOXR_SHA256=b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889
XZ_VERSION=5.8.4
XZ_SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9
# ... and both ARM builds' (ffmpeg's and the packages')
LIBWEBP_VERSION=1.6.0
LIBWEBP_SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
# ... and the ARM packages' only
JPEG_VERSION=3.2.1
JPEG_SHA256=c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f
DE265_VERSION=1.1.3
DE265_SHA256=554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905
HEIF_VERSION=1.23.7
HEIF_SHA256=f7483e818503ea6224c8863e4a56ac02c7089021a98472c811c12aa19faf2475
FFI_VERSION=3.8.1
FFI_SHA256=81e879c094cc5ec3186c48510c6385ac6b3e866192e8bc71a35245703757ee40
# The ARM models' packages: built from their source (with setuptools, or - argon2-cffi-bindings, built with CMake -
# compiled by hand), and left out (only the SFTP server needs them); the rest of the lock is pure Python
ARM_BUILT='cffi markupsafe pillow pillow-heif'
ARM_BUILT_BY_HAND='argon2-cffi-bindings'
ARM_SKIPPED='paramiko cryptography bcrypt pynacl invoke'
# The newest glibc symbol versions the NAS has (OS5: glibc 2.31 on the Intel models; the ARM build is held to 2.17,
# python-build-standalone's own)
NAS_GLIBC=2.31
NAS_GLIBC_ARMHF=2.17
# The architectures built (each into packages/static/copyparty/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=${BUILD_PATH}/tools
SOURCES_PATH=${BUILD_PATH}/sources
OUTPUT_ROOT=/data/packages/static/copyparty/${VERSION}
# CopyParty's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/copyparty/requirements.txt
# The ARM models' processors, as Zig names them; QEMU runs ARM programs as one (with Debian's ARM glibc, for those
# that use glibc)
ARM_CPU=cortex_a9
QEMU='qemu-arm -cpu cortex-a9'

# Downloads a file into the current folder and checks it against its SHA256 (static/fetch.sh: a kept copy, its site,
# then any other sites given, then the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
# $@        Other sites with the very same file
function fetch() {
    sh /data/static/fetch.sh "$@"
}

# Prepares the tools: uv, an untouched Intel Python (its pip assembles the ARM packages, and builds them), Zig and its
# commands for the ARM models - arm-musl-cc (ffmpeg's, fully static), arm-gnu-cc / arm-gnu-c++ (the packages', for
# glibc 2.17), arm-ar, arm-ranlib - and a CMake toolchain file for each kind (musl.cmake, gnu.cmake).
function build_tools() {
    local kind target

    mkdir -p ${TOOLS_PATH}/bin
    cd ${TOOLS_PATH}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz
    fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" zig.tar.xz ${ZIG_SHA256}
    tar -xJf zig.tar.xz
    ln -s ${TOOLS_PATH}/zig-x86_64-linux-${ZIG_VERSION}/zig bin/zig
    export PATH="${TOOLS_PATH}/bin:${PATH}"

    for kind in musl-cc gnu-cc gnu-c++; do
        case "${kind}" in
            musl-*) target=arm-linux-musleabihf ;;
            gnu-*) target=arm-linux-gnueabihf.2.17 ;;
        esac

        # (the builds' own processor options are dropped: Zig names processors its own way, and -mcpu names the
        # ARM models')
        cat > bin/arm-${kind} <<SH
#!/bin/sh
for arg in "\$@"; do
    shift

    case "\${arg}" in
        -mcpu=*|-march=*|-mfpu=*) continue ;;
    esac

    set -- "\$@" "\${arg}"
done

exec zig ${kind#*-} -target ${target} -mcpu=${ARM_CPU} "\$@"
SH
    done

    printf '#!/bin/sh\nexec zig ar "$@"\n' > bin/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > bin/arm-ranlib
    chmod 755 bin/*

    for kind in musl gnu; do
        cat > ${kind}.cmake <<CMAKE
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR armv7l)
set(CMAKE_C_COMPILER ${TOOLS_PATH}/bin/arm-${kind}-cc)
set(CMAKE_CXX_COMPILER ${TOOLS_PATH}/bin/arm-gnu-c++)
set(CMAKE_AR ${TOOLS_PATH}/bin/arm-ar)
set(CMAKE_RANLIB ${TOOLS_PATH}/bin/arm-ranlib)
set(CMAKE_CROSSCOMPILING_EMULATOR ${QEMU// /;}$( [ ${kind} = gnu ] && echo ';-L;/armhf-root' || true))
set(CMAKE_FIND_ROOT_PATH ${BUILD_PATH}/deps-${kind})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
    done

    # The tools the ARM packages are built with, in the Intel Python
    ${TOOLS_PATH}/python/bin/python3 -m pip install --quiet --disable-pip-version-check pybind11 setuptools wheel

    # CopyParty's lock, written once (see LOCK)
    if [ ! -f ${LOCK} ]; then
        { echo "copyparty==${VERSION}"; echo "${CPP_PACKAGES}" | tr ' ' '\n'; } > requirements.in
        ./uv-x86_64-unknown-linux-musl/uv pip compile --quiet --python ${TOOLS_PATH}/python/bin/python3 \
            --generate-hashes --no-header requirements.in -o ${LOCK}
    fi

    # The lock must hold CopyParty's own published checksum
    grep -q "${CPP_WHEEL_SHA256}" ${LOCK}
}

# Downloads the ARM builds' sources into ${SOURCES_PATH}, each checked against its SHA256.
function download() {
    mkdir -p ${SOURCES_PATH}
    cd ${SOURCES_PATH}
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_ARMHF_SHA256}
    # (Debian's and Alpine's copies of the very same file, if ffmpeg.org is down)
    fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz ${FFMPEG_SHA256} \
        "https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_${FFMPEG_VERSION}.orig.tar.xz" \
        "https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" opus.tar.gz ${OPUS_SHA256}
    fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" \
        lame.tar.gz ${LAME_SHA256}
    fetch "https://github.com/xiph/ogg/releases/download/v${OGG_VERSION}/libogg-${OGG_VERSION}.tar.gz" ogg.tar.gz \
        ${OGG_SHA256}
    fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz" vorbis.tar.xz \
        ${VORBIS_SHA256}
    fetch "https://downloads.sourceforge.net/project/soxr/soxr-${SOXR_VERSION}-Source.tar.xz" soxr.tar.xz \
        ${SOXR_SHA256}
    fetch "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" xz.tar.gz \
        ${XZ_SHA256}
    fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" \
        webp.tar.gz ${LIBWEBP_SHA256}
    fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" zlib.tar.gz \
        ${ZLIB_SHA256}
    fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/libjpeg-turbo-${JPEG_VERSION}.tar.gz" \
        jpeg.tar.gz ${JPEG_SHA256}
    fetch "https://github.com/strukturag/libde265/releases/download/v${DE265_VERSION}/libde265-${DE265_VERSION}.tar.gz" \
        de265.tar.gz ${DE265_SHA256}
    fetch "https://github.com/strukturag/libheif/releases/download/v${HEIF_VERSION}/libheif-${HEIF_VERSION}.tar.gz" \
        heif.tar.gz ${HEIF_SHA256}
    fetch "https://github.com/libffi/libffi/releases/download/v${FFI_VERSION}/libffi-${FFI_VERSION}.tar.gz" \
        ffi.tar.gz ${FFI_SHA256}
}

# Sets up the ARM library builds of a kind (the variables every step below uses): musl for ffmpeg (fully static), gnu
# for the packages (glibc 2.17, position-independent: linked into their modules) - each into ${BUILD_PATH}/deps-<kind>.
#
# $1 kind musl or gnu
function use_kind() {
    KIND="$1"
    DEPS=${BUILD_PATH}/deps-${KIND}
    WORK=${BUILD_PATH}/work-${KIND}
    TOOLCHAIN=${TOOLS_PATH}/${KIND}.cmake
    mkdir -p ${DEPS} ${WORK}

    if [ "${KIND}" = musl ]; then
        HOST=arm-linux-musleabihf
    else
        HOST=arm-linux-gnueabihf
    fi

    export CC=${TOOLS_PATH}/bin/arm-${KIND}-cc CXX=${TOOLS_PATH}/bin/arm-gnu-c++ AR=${TOOLS_PATH}/bin/arm-ar \
        RANLIB=${TOOLS_PATH}/bin/arm-ranlib CFLAGS='-O2 -fPIC' CXXFLAGS='-O2 -fPIC' \
        PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR=${DEPS}/lib/pkgconfig
}

# Ends the ARM library builds of a kind: the commands after them build for this machine (or set their own).
function leave_kind() {
    unset CC CXX AR RANLIB CFLAGS CXXFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
}

# Unpacks a source into ${WORK} and goes into it.
#
# $1 file Its file, in ${SOURCES_PATH}
function unpack() {
    local folder="${WORK}/${1%%.tar.*}"

    rm -rf "${folder}"
    mkdir -p "${folder}"
    tar -xf "${SOURCES_PATH}/$1" -C "${folder}" --strip-components=1
    cd "${folder}"
}

# Builds a library of the current kind with its configure script, as a static library only.
#
# $1 file Its source's file
# $@      configure's other options
function build_configure() {
    unpack "$1"
    shift
    ./configure --build=x86_64-linux-gnu --host=${HOST} --prefix=${DEPS} --disable-shared --enable-static "$@"
    make -j "$(nproc)"
    make install
}

# Builds a library of the current kind with CMake, as a static library only.
#
# $1 file Its source's file
# $@      CMake's other options
function build_cmake() {
    unpack "$1"
    shift
    cmake -S . -B out -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN} -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${DEPS} \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH=${DEPS} -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@"
    cmake --build out -j "$(nproc)"
    cmake --install out
}

# Builds zlib of the current kind (its configure script is its own).
function build_zlib() {
    unpack zlib.tar.gz
    ./configure --prefix=${DEPS} --static
    make -j "$(nproc)"
    make install
}

# Builds libwebp of the current kind (with its mux / demux libraries, which ffmpeg and Pillow use).
function build_webp() {
    build_configure webp.tar.gz --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif \
        --disable-wic --enable-libwebpmux --enable-libwebpdemux
}

# Builds the ARM models' ffmpeg and ffprobe (fully static, musl) with its libraries - as the Dockerfile builds the
# Intel models' - into ${BUILD_PATH}/armhf-ffmpeg.
function build_ffmpeg() {
    use_kind musl
    build_zlib
    build_configure xz.tar.gz --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts \
        --disable-doc --disable-nls
    build_configure ogg.tar.gz
    build_configure vorbis.tar.xz --disable-docs --disable-examples
    build_configure opus.tar.gz --disable-doc --disable-extra-programs
    build_configure lame.tar.gz --disable-frontend --disable-gtktest --disable-decoder
    build_webp
    # (without OpenMP: the Intel models' Alpine one has it, which only speeds up long resamplings)
    build_cmake soxr.tar.xz -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF

    unpack ffmpeg.tar.xz
    ./configure --enable-cross-compile --arch=arm --cpu=cortex-a9 --target-os=linux --cc=${CC} --ar=${AR} \
        --ranlib=${RANLIB} --nm=arm-linux-gnueabihf-nm --strip=arm-linux-gnueabihf-strip \
        --pkg-config=pkg-config --pkg-config-flags=--static --extra-cflags="-I${DEPS}/include" \
        --extra-ldflags="-L${DEPS}/lib -static" --enable-static --disable-shared --disable-doc --disable-debug \
        --disable-ffplay --disable-autodetect --disable-avdevice --disable-network --enable-version3 \
        --enable-libsoxr --enable-libopus --enable-libmp3lame --enable-libvorbis --enable-libwebp --enable-zlib \
        --enable-lzma
    make -j "$(nproc)"
    arm-linux-gnueabihf-strip ffmpeg ffprobe
    mkdir -p ${BUILD_PATH}/armhf-ffmpeg
    cp ffmpeg ffprobe ${BUILD_PATH}/armhf-ffmpeg/
    leave_kind
}

# Builds the libraries the ARM packages' compiled parts use (glibc, position-independent): libffi (cffi's), zlib,
# libjpeg-turbo and libwebp (Pillow's), and libde265 and libheif (pillow-heif's: HEIC pictures, read only - libheif's
# archive then holds libde265 too, as pillow-heif only links libheif; libwebp's, libsharpyuv).
function build_package_libraries() {
    use_kind gnu
    build_configure ffi.tar.gz --with-pic --disable-docs --disable-multi-os-directory
    build_zlib
    build_cmake jpeg.tar.gz -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF
    build_webp
    build_cmake de265.tar.gz -DENABLE_SDL=OFF -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF
    build_cmake heif.tar.gz -DWITH_LIBDE265=ON -DWITH_X265=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF \
        -DWITH_DAV1D=OFF -DWITH_RAV1E=OFF -DWITH_SvtEnc=OFF -DWITH_KVAZAAR=OFF -DWITH_OpenH264_DECODER=OFF \
        -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF \
        -DWITH_FFMPEG_DECODER=OFF -DWITH_LIBSHARPYUV=OFF -DWITH_GDK_PIXBUF=OFF -DWITH_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF -DENABLE_PLUGIN_LOADING=OFF

    # (Pillow links libwebp without libsharpyuv, which it uses: its archive holds it too)
    cd ${DEPS}/lib
    printf 'create libheif-all.a\naddlib libheif.a\naddlib libde265.a\nsave\nend\n' | arm-ar -M
    printf 'create libwebp-all.a\naddlib libwebp.a\naddlib libsharpyuv.a\nsave\nend\n' | arm-ar -M
    mv libheif-all.a libheif.a
    mv libwebp-all.a libwebp.a
    leave_kind
}

# Puts an architecture's Python into the current folder, as ./python (the ARM one with its launcher).
#
# $1 arch The architecture (amd64 or armhf)
function build_python() {
    # (the Intel one unpacked again: the tools' has the build tools in it)
    if [ "$1" != armhf ]; then
        tar -xzf ${TOOLS_PATH}/python.tar.gz

        return
    fi

    tar -xzf ${SOURCES_PATH}/python.tar.gz

    cat > launcher.c <<'C'
// python3.14 for the ARM models: runs Python as python3.14 itself does, from libpython (laid out for their kernels'
// large memory pages, where python-build-standalone's own python3.14 isn't)
extern int Py_BytesMain(int argc, char **argv);

int main(int argc, char **argv)
{
	return Py_BytesMain(argc, argv);
}
C
    arm-gnu-cc -O2 -s launcher.c -o python/bin/python3.14 -Lpython/lib -lpython3.14 -Wl,-rpath,'$ORIGIN/../lib'
}

# Writes the lock's entries for some packages (or for all but them) to a file.
#
# $1 mode     only or except
# $2 file     The file written
# $@ packages Their names
function lock_part() {
    local mode="$1"
    local file="$2"
    shift 2

    python3 - "${LOCK}" "${mode}" "$@" > "${file}" <<'PY'
import re
import sys

lock, mode, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
entry = None

for line in open(lock, encoding="utf-8"):
    match = re.match(r"^([A-Za-z0-9_.-]+)==", line)

    if match:
        entry = re.sub(r"[-_.]+", "-", match.group(1)).lower()

    if not line.startswith(("#", " ")) and not match:
        entry = None

    # (the entries' "# via" comments are left out)
    if entry and not line.lstrip().startswith("#") and (entry in names) == (mode == "only"):
        print(line, end="")
PY
}

# Installs CopyParty and its packages into the Intel Python (./python), from the lock - the wheels for the NAS's glibc
# (not this machine's, which is newer).
function install_intel() {
    ${TOOLS_PATH}/uv-x86_64-unknown-linux-musl/uv pip install --python python/bin/python3 --break-system-packages \
        --python-platform x86_64-manylinux_${NAS_GLIBC/./_} --require-hashes -r ${LOCK}
    # Not needed on the NAS: pip (packages come with the app)
    ${TOOLS_PATH}/uv-x86_64-unknown-linux-musl/uv pip uninstall --python python/bin/python3 --break-system-packages \
        pip
}

# Runs a command (the Intel Python's) as if for the ARM Python in the current folder: Python's build settings are the
# ARM one's (its headers, its modules' names, linux_armv7l wheels), compiling with Zig for glibc 2.17, with the
# libraries in ${BUILD_PATH}/deps-gnu.
#
# $@ The command and its arguments
function for_arm() {
    local deps=${BUILD_PATH}/deps-gnu
    local settings

    settings="$(basename python/lib/python3.14/_sysconfigdata_*arm*.py .py)"
    mkdir -p arm-settings
    cp python/lib/python3.14/${settings}.py arm-settings/

    (
        export _PYTHON_HOST_PLATFORM=linux-armv7l _PYTHON_SYSCONFIGDATA_NAME=${settings}
        export PYTHONPATH=${PWD}/arm-settings
        export CC=arm-gnu-cc CXX=arm-gnu-c++ LDSHARED='arm-gnu-c++ -shared' LDCXXSHARED='arm-gnu-c++ -shared'
        export AR=arm-ar RANLIB=arm-ranlib
        export CFLAGS="-I${PWD}/python/include/python3.14 -I${deps}/include -O2 -fPIC"
        export CXXFLAGS="${CFLAGS}" LDFLAGS="-L${deps}/lib -pthread"
        export PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR=${deps}/lib/pkgconfig
        "$@"
    )
}

# Installs CopyParty and its packages into the ARM Python (./python): PyPI's pure Python wheels, and wheels built here
# from their source for the rest - every download checked against the lock's checksums.
function install_arm() {
    local pip="${TOOLS_PATH}/python/bin/python3 -m pip --disable-pip-version-check"
    local site=${PWD}/python/lib/python3.14/site-packages
    local wheels=${PWD}/wheels
    local source folder

    mkdir -p ${wheels} sources
    # shellcheck disable=SC2086
    lock_part except pure.txt ${ARM_BUILT} ${ARM_BUILT_BY_HAND} ${ARM_SKIPPED}
    # shellcheck disable=SC2086
    lock_part only built.txt ${ARM_BUILT} ${ARM_BUILT_BY_HAND}
    ${pip} download --no-deps --require-hashes --only-binary :all: --platform any --python-version 3.14 \
        --implementation py --abi none -d ${wheels} -r pure.txt
    # (their sources - only theirs: their build tools may be wheels)
    ${pip} download --no-deps --require-hashes --no-binary "$(echo ${ARM_BUILT} ${ARM_BUILT_BY_HAND} | tr ' ' ,)" \
        -d sources -r built.txt

    # cffi and MarkupSafe as they are; Pillow with what CopyParty's thumbnails use (JPEG, PNG, WebP; and GIF, BMP...,
    # which need no library), nothing found on this machine itself; pillow-heif without -Werror (Zig's compiler warns
    # where its own doesn't)...
    for source in sources/cffi-*.tar.gz sources/markupsafe-*.tar.gz; do
        for_arm ${pip} wheel --no-deps --no-build-isolation -w ${wheels} "${source}"
    done

    for_arm ${pip} wheel --no-deps --no-build-isolation -w ${wheels} -C platform-guessing=disable -C zlib=enable \
        -C jpeg=enable -C webp=enable -C tiff=disable -C freetype=disable -C lcms=disable -C jpeg2000=disable \
        -C imagequant=disable -C xcb=disable -C raqm=disable -C avif=disable sources/pillow-*.tar.gz

    folder=build-pillow-heif
    rm -rf ${folder}
    mkdir -p ${folder}
    tar -xzf sources/pillow_heif-*.tar.gz -C ${folder} --strip-components=1
    # (nor this machine's own folders, or its Python's: it adds them for Linux - they would mix this machine's headers
    # and libraries into the ARM build)
    sed -i -e 's/, "-Werror"//' -e '/_add_directory([a-z_]*, "\/\(usr\|lib\)/d' \
        -e '/_add_directory([a-z_]*, os.path.join(sys.prefix/d' ${folder}/setup.py

    if grep -n '"/usr\|"/lib"\|sys.prefix' ${folder}/setup.py; then
        echo "pillow-heif's setup.py still adds this machine's folders"

        exit 1
    fi

    for_arm ${pip} wheel --no-deps --no-build-isolation -w ${wheels} ./${folder}

    build_argon2_bindings

    ${pip} install --no-deps --no-index --only-binary :all: --target ${site} --python-version 3.14 \
        --implementation cp --abi cp314 --abi abi3 --abi none --platform linux_armv7l --platform any ${wheels}/*.whl
    # (no scripts: the app runs CopyParty with python -m)
    rm -rf ${site}/bin

    # Every package in the lock, installed - but the skipped ones (and the pip python-build-standalone comes with)
    [ "$(ls -d ${site}/*.dist-info | grep -cv '/pip-')" \
        = "$(( $(grep -cE '^[A-Za-z0-9_.-]+==' ${LOCK}) - $(echo ${ARM_SKIPPED} | wc -w) ))" ]
}

# Builds argon2-cffi-bindings' wheel for the ARM models into ./wheels: built with CMake (scikit-build-core), which
# doesn't cross-compile, so its wheel is built for this machine, and its one compiled part (_ffi.abi3.so: its CFFI
# module with Argon2's portable C code, as its CMakeLists.txt builds it for processors without SSE2) replaced by one
# compiled for the ARM models.
function build_argon2_bindings() {
    local pip="${TOOLS_PATH}/python/bin/python3 -m pip --disable-pip-version-check"
    local wheel="${TOOLS_PATH}/python/bin/python3 -m wheel"
    local folder=build-argon2
    local root unpacked

    rm -rf ${folder}
    mkdir -p ${folder}/source ${folder}/intel ${folder}/arm
    tar -xzf sources/argon2_cffi_bindings-*.tar.gz -C ${folder}/source --strip-components=1
    # (with this machine's compiler: scikit-build-core would take the one python-build-standalone was built with)
    CC=gcc ${pip} wheel --no-deps -w ${folder}/intel ${folder}/source

    root=${folder}/source/extras/libargon2
    arm-gnu-cc -O2 -fPIC -shared -DPy_LIMITED_API=0x030A0000 -I${PWD}/python/include/python3.14 -I${root}/include \
        ${folder}/source/src/_argon2_cffi_bindings/_ffi.c ${root}/src/argon2.c ${root}/src/blake2/blake2b.c \
        ${root}/src/core.c ${root}/src/encoding.c ${root}/src/ref.c ${root}/src/thread.c -pthread \
        -o ${folder}/_ffi.abi3.so

    ${wheel} unpack -d ${folder}/arm ${folder}/intel/*.whl
    unpacked="$(ls -d ${folder}/arm/*/)"
    cp ${folder}/_ffi.abi3.so "${unpacked}_argon2_cffi_bindings/_ffi.abi3.so"
    ${wheel} pack -d ${folder} "${unpacked}"
    ${wheel} tags --platform-tag linux_armv7l --remove ${folder}/*.whl
    mv ${folder}/*.whl wheels/
}

# Trims an architecture's Python (./python) to what a server needs, and compiles its bytecode.
#
# $1 arch The architecture (amd64 or armhf)
function trim() {
    local lib=python/lib/python3.14

    # Not needed by a server: the terminal database (for interactive programs), whose folders differ only in case -
    # which a case-insensitive file system (e.g. a Windows drive holding the repository) can't store
    rm -rf python/share/terminfo

    if [ "$1" = armhf ]; then
        # (and pip, which the Intel one has removed by uv)
        rm -rf ${lib}/site-packages/pip ${lib}/site-packages/pip-* python/bin/pip*
        find ${lib}/site-packages -name '*.so' -exec arm-linux-gnueabihf-strip --strip-unneeded {} +
    fi

    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user) - by the Intel
    # Python for both (the same Python version: the same bytecode)
    ${TOOLS_PATH}/python/bin/python3 -m compileall -q ${lib}/site-packages > /dev/null || true
}

# Checks that every compiled part of an architecture's Python (./python) runs with the NAS's glibc.
#
# $1 arch The architecture (amd64 or armhf)
function check_glibc() {
    local objdump=objdump
    local newest=${NAS_GLIBC}
    local found=0
    local file version

    if [ "$1" = armhf ]; then
        objdump=arm-linux-gnueabihf-objdump
        newest=${NAS_GLIBC_ARMHF}
    fi

    while read -r file; do
        head -c 4 "${file}" | grep -q ELF || continue

        for version in $(${objdump} -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${newest#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(find python -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${newest})"

        exit 1
    fi
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
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
    if [ "$1" = armhf ]; then
        arm-musl-cc -O2 -static -s -o cpp_runas cpp_runas.c
    else
        gcc -O2 -static -s -o cpp_runas cpp_runas.c
    fi
}

# Makes the files the ARM checks use, in ${BUILD_PATH}/samples, with the Intel build (./python in ${BUILD_PATH}/amd64):
# a JPEG, a PNG and a HEIC picture (the Intel pillow-heif can write HEIC; the ARM one only reads it), and a WAV.
function make_samples() {
    mkdir -p ${BUILD_PATH}/samples
    ${BUILD_PATH}/amd64/python/bin/python3 - ${BUILD_PATH}/samples <<'PY'
import math
import struct
import sys
import wave

import pillow_heif
from PIL import Image

folder = sys.argv[1]
picture = Image.new("RGB", (320, 200))

for x in range(320):
    for y in range(200):
        picture.putpixel((x, y), (x % 256, y % 256, (x * y) % 256))

picture.save(folder + "/picture.jpg", quality=90)
picture.save(folder + "/picture.png")
pillow_heif.from_pillow(picture).save(folder + "/picture.heic", quality=80)

with wave.open(folder + "/tone.wav", "wb") as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(48000)
    out.writeframes(b"".join(
        struct.pack("<hh", int(8000 * math.sin(i / 20)), int(8000 * math.sin(i / 30))) for i in range(48000)
    ))
PY
}

# Checks an architecture's build in the current folder: (ARM) laid out for large memory pages; CopyParty's packages
# importing and working - passwords hashed, pictures (HEIC too) made into thumbnails; and (ARM) CopyParty serving a
# folder and a picture's thumbnail, and ffmpeg making WebP, Opus, MP3 and Vorbis (resampled with soxr) - with QEMU.
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local run=''
    local python=${PWD}/python/bin/python3
    local samples=${BUILD_PATH}/samples
    local result pid page format attempt

    if [ "${arch}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py python cpp_runas ffmpeg ffprobe
        run="${QEMU} -L /armhf-root"
    fi

    ${run} ${python} -m copyparty --version
    result="$(${run} ${python} - ${samples} <<'PY'
import io
import sys

import argon2
import copyparty
import jinja2
import markupsafe
import mutagen
import pillow_heif
from PIL import Image, features

hasher = argon2.PasswordHasher()
hashed = hasher.hash("secret")
pillow_heif.register_heif_opener()
sizes = []

for name in ("picture.jpg", "picture.png", "picture.heic"):
    picture = Image.open(sys.argv[1] + "/" + name)
    picture.thumbnail((128, 128))

    for kind in ("WEBP", "JPEG"):
        out = io.BytesIO()
        picture.save(out, kind)
        sizes.append(Image.open(io.BytesIO(out.getvalue())).size)

print(hasher.verify(hashed, "secret"), features.check("webp"), features.check("jpg"), features.check("zlib"),
      set(sizes) == {(128, 80)}, markupsafe.escape("<") == "&lt;", hasattr(markupsafe, "_speedups"))
PY
)"
    echo "${result}"
    [ "${result}" = 'True True True True True True True' ]
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${run} ./cpp_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: cpp_runas'

    [ "${arch}" = armhf ] || return 0

    # CopyParty serving the samples' folder (started directly, so that stopping it stops CopyParty itself), with a
    # thumbnail of the HEIC picture
    ${run} ${python} -m copyparty -q -p 3923 -i 127.0.0.1 -v ${samples}::r --hist ${BUILD_PATH}/cpp-hist \
        > ${BUILD_PATH}/copyparty.log 2>&1 &
    pid=$!
    page=''

    for attempt in $(seq 1 120); do
        page="$(wget -qO- 'http://127.0.0.1:3923/?ls' 2>/dev/null || true)"
        [ -n "${page}" ] && break
        sleep 1
    done

    for attempt in $(seq 1 60); do
        format="$(wget -qO- 'http://127.0.0.1:3923/picture.heic?th=w' 2>/dev/null | head -c 12 | tail -c 4 || true)"
        [ "${format}" = WEBP ] && break
        sleep 1
    done

    kill ${pid}
    wait ${pid} || true

    if ! echo "${page}" | grep -q 'picture.heic' || [ "${format}" != WEBP ]; then
        cat ${BUILD_PATH}/copyparty.log

        exit 1
    fi

    # ffmpeg: a WebP picture, and the tone as Opus, MP3 and Vorbis, resampled to 24kHz with soxr
    ${QEMU} ./ffmpeg -hide_banner -version > ${BUILD_PATH}/ffmpeg-version.txt
    head -n 1 ${BUILD_PATH}/ffmpeg-version.txt
    ${QEMU} ./ffmpeg -hide_banner -loglevel error -y -i ${samples}/picture.png ${BUILD_PATH}/picture.webp
    for format in opus:libopus mp3:libmp3lame ogg:libvorbis; do
        ${QEMU} ./ffmpeg -hide_banner -loglevel error -y -i ${samples}/tone.wav -af aresample=resampler=soxr \
            -ar 24000 -c:a ${format#*:} ${BUILD_PATH}/tone.${format%%:*}
        ${QEMU} ./ffprobe -v error -show_entries stream=codec_name,sample_rate -of csv=p=0 \
            ${BUILD_PATH}/tone.${format%%:*}
    done
    [ "$(head -c 12 ${BUILD_PATH}/picture.webp | tail -c 4)" = WEBP ]
}

function run() {
    local arch output

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_tools
    download
    build_ffmpeg
    build_package_libraries

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_python ${arch}

        if [ "${arch}" = armhf ]; then
            install_arm
            cp ${BUILD_PATH}/armhf-ffmpeg/ffmpeg ${BUILD_PATH}/armhf-ffmpeg/ffprobe ./
        else
            install_intel
            cp /opt/ffmpeg /opt/ffprobe ./
            make_samples
        fi

        trim ${arch}
        check_glibc ${arch}
        build_runas ${arch}
        check ${arch}

        # Nothing may differ only in case (see trim)
        if [ -n "$(find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
            find python | tr '[:upper:]' '[:lower:]' | sort | uniq -d
            echo 'These paths differ only in case'

            exit 1
        fi

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        output=${OUTPUT_ROOT}/${arch}
        rm -rf ${output}
        mkdir -p ${output}
        cp -a python ${output}/python
        cp cpp_runas ffmpeg ffprobe ${output}/
        du -sh ${output} ${output}/*
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/copyparty/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/copyparty/requirements.txt
}

run
