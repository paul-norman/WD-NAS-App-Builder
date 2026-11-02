#!/bin/bash

# Prepares Calibre-Web for the NAS, with everything it uses:
#  - Calibre-Web, with its metadata (book details from Google Books, Amazon...), comics and Kobo sync features, in its own
#    Python (a portable build)
#  - Calibre's own programs (ebook-convert, calibredb, ebook-meta...): conversion between e-book formats, and the library
#  - kepubify (Kobo's e-book format), ImageMagick (covers, through Python's Wand), Ghostscript (covers of PDFs) and libmagic
#  - cw_runas: switches to Calibre-Web's own user (the NAS has no su or similar) before running it
#
# Calibre 9 needs glibc 2.34 or newer; the NAS has 2.31. So the app brings its own: Debian Bookworm's glibc (2.36) and
# the other libraries these programs expect from a system, in binaries/runtime. Every program here is patched to start
# with that runtime's loader, and every program and library to look in it first - nothing else on the NAS is affected
# (WD's own programs keep the NAS's glibc). The loader is found by its full path, so everything is prepared exactly
# where the app lives on the NAS (Nas_Prog on the first volume)

set -e
set -o pipefail
set -x

VERSION=0.6.27
CW_WHEEL_SHA256=c6d4173d31a4495e09c615857f30f0d03d9f7eabc7bb50558164f67083d4f72d
CW_EXTRAS=comics,kobo
# Its "metadata" feature's packages (as Calibre-Web lists them), without scholarly: Google Scholar as a source of book
# details, which brings a browser automation framework and documentation tools along (over 100MB). Calibre-Web just
# doesn't offer that source without it
CW_METADATA="rarfile>=3.2,<5.0 markdown2>=2.0.0,<2.6.0 html2text>=2020.1.16,<2025.4.16 python-dateutil>=2.1,<2.10.0
beautifulsoup4>=4.0.1,<4.16.0 faust-cchardet>=2.1.18,<2.1.20 py7zr>=0.15.0,<0.21.0 mutagen>=1.40.0,<1.50.0
pycountry>=20.0.0,<27.0.0"
CALIBRE_VERSION=9.17.0
# Calibre's own, from https://calibre-ebook.com/signatures/calibre-<version>-x86_64.txz.sha512
CALIBRE_SHA512=9faf38f6bb0593598208fbde1be247d698a98d9f16e130ca6507049a02b1d9b65f7d10eeca15f5073d0372f7bb2d45d6c63d39a37f1b13a3cbaf81918e715711
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
KEPUBIFY_VERSION=4.0.4
KEPUBIFY_SHA256=37d7628d26c5c906f607f24b36f781f306075e7073a6fe7820a751bb60431fc5
# The runtime's glibc: nothing may need a newer one
RUNTIME_GLIBC=2.36

# Where the app's binaries are on the NAS
APP=/mnt/HD/HD_a2/Nas_Prog/calibre-web/binaries
RUNTIME=${APP}/runtime
BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/calibre-web/${VERSION}/amd64
# Calibre-Web's packages, each version with the checksums of its files: written by the first build, then reused (so that
# rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/calibre-web/requirements.txt

# Downloads a file and checks it: $1 address, $2 file name, $3 checksum, $4 sha256 (default) or sha512
function fetch() {
    cd ${BUILD_PATH}
    wget -q "$1" -O "$2"
    echo "$3  $2" | ${4:-sha256}sum -c -
}

function get_calibre() {
    fetch "https://github.com/kovidgoyal/calibre/releases/download/v${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-x86_64.txz" \
        calibre.txz ${CALIBRE_SHA512} sha512
    mkdir -p ${APP}/calibre
    tar -xJf calibre.txz -C ${APP}/calibre
}

function get_calibre_web() {
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz -C ${APP}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    local uv=${BUILD_PATH}/uv-x86_64-unknown-linux-musl/uv

    if [ ! -f ${LOCK} ]; then
        { echo "calibreweb[${CW_EXTRAS}]==${VERSION}"; echo "${CW_METADATA}" | tr ' ' '\n'; } > requirements.in
        ${uv} pip compile --quiet --python ${APP}/python/bin/python3 --generate-hashes --no-header requirements.in -o ${LOCK}
    fi
    # The lock must hold Calibre-Web's own published checksum
    grep -q "${CW_WHEEL_SHA256}" ${LOCK}
    ${uv} pip install --python ${APP}/python/bin/python3 --break-system-packages --require-hashes -r ${LOCK}
    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${APP}/python/bin/python3 -m compileall -q ${APP}/python/lib/python3.14/site-packages > /dev/null || true
    # Not needed by a server: the terminal database (its folders also differ only in case, which a Windows drive holding
    # the repository can't store) and IDLE
    rm -rf ${APP}/python/share/terminfo ${APP}/python/lib/python3*/idlelib ${APP}/python/bin/idle3*
    # Nor pip: nothing is installed into it on the NAS
    rm -rf ${APP}/python/lib/python3*/site-packages/pip ${APP}/python/lib/python3*/site-packages/pip-* ${APP}/python/bin/pip*
}

function get_kepubify() {
    fetch "https://github.com/pgaskin/kepubify/releases/download/v${KEPUBIFY_VERSION}/kepubify-linux-64bit" kepubify ${KEPUBIFY_SHA256}
    # By its release's name: the only one Calibre-Web accepts on Linux
    install -m 755 kepubify ${APP}/kepubify-linux-64bit
}

# ImageMagick (its libraries where Python's Wand looks: $MAGICK_HOME/lib), its format modules and settings - with a
# policy that lets it read PDFs (Debian's stops it), for their covers - Ghostscript (which it uses for PDFs) and
# libmagic's file type database
function get_imaging() {
    local magick
    magick=$(ls -d /usr/lib/x86_64-linux-gnu/ImageMagick-6.*)
    mkdir -p ${APP}/magick/lib ${APP}/magick/etc ${APP}/bin ${APP}/ghostscript ${RUNTIME}
    # The libraries themselves go in the runtime, where they find each other, and Wand finds them through links
    cp -L /usr/lib/x86_64-linux-gnu/libMagickWand-6.Q16.so.6 /usr/lib/x86_64-linux-gnu/libMagickCore-6.Q16.so.6 ${RUNTIME}/
    ln -sf ../../runtime/libMagickWand-6.Q16.so.6 ${APP}/magick/lib/libMagickWand-6.Q16.so
    ln -sf ../../runtime/libMagickCore-6.Q16.so.6 ${APP}/magick/lib/libMagickCore-6.Q16.so
    cp -r ${magick}/modules-Q16 ${APP}/magick/
    # Not HEIC photos: its module brings two video encoders along, over 20MB - covers don't use it
    rm -f ${APP}/magick/modules-Q16/coders/heic.*
    cp -r /etc/ImageMagick-6/* ${APP}/magick/etc/
    sed -i '/pattern="PDF"\|pattern="PS"\|pattern="EPS"\|pattern="XPS"/d' ${APP}/magick/etc/policy.xml
    cp -L /usr/bin/gs ${APP}/bin/gs
    cp -r /usr/share/ghostscript/*/Resource /usr/share/ghostscript/*/lib ${APP}/ghostscript/ 2>/dev/null || true
    cp -rL /usr/share/ghostscript/fonts ${APP}/ghostscript/ 2>/dev/null || true
    # Its colour profiles: without them it can't open any output device
    cp -r /usr/share/color/icc/ghostscript ${APP}/ghostscript/iccprofiles
    cp -L /usr/lib/file/magic.mgc ${APP}/magic.mgc
    # Python's magic loads libmagic itself - nothing links to it - so it's placed in the runtime by name
    cp -L /usr/lib/x86_64-linux-gnu/libmagic.so.1 ${RUNTIME}/
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > cw_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: cw_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("cw_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("cw_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o cw_runas cw_runas.c
    strip cw_runas
    install -m 755 cw_runas ${APP}/cw_runas
}

# Every ELF file in the app, except the runtime itself and the static programs
function app_elfs() {
    find ${APP} -path ${RUNTIME} -prune -o -type f -print0 | xargs -0 file | grep -E ': *ELF' | grep -v 'statically linked' | cut -d: -f1
}

# The runtime: every library these programs resolve to outside the app - found as they're found when they run: Calibre's
# own files with its library folders searched first (its launchers set that up), everything else (Python and its
# packages, ImageMagick, Ghostscript) only through their own paths - plus glibc's loader. (Calibre bundles some of the
# same libraries, e.g. expat and lcms2: ImageMagick doesn't see Calibre's, so it needs the runtime's)
function build_runtime() {
    mkdir -p ${RUNTIME}
    app_elfs > ${BUILD_PATH}/elfs
    local dirs
    dirs=$(find ${APP}/calibre -name '*.so*' -printf '%h\n' | sort -u | tr '\n' ':')
    {
        grep "^${APP}/calibre/" ${BUILD_PATH}/elfs | xargs -d '\n' -n 50 env LD_LIBRARY_PATH="${dirs}" ldd 2>/dev/null
        # And the libraries already placed in the runtime - ImageMagick's
        { grep -v "^${APP}/calibre/" ${BUILD_PATH}/elfs; ls ${RUNTIME}/*; } | xargs -d '\n' -n 50 ldd 2>/dev/null
    } > ${BUILD_PATH}/ldd.txt || true
    awk '$2 == "=>" && $3 ~ /^\// { print $3 }' ${BUILD_PATH}/ldd.txt | grep -v "^${APP}/" | sort -u > ${BUILD_PATH}/system_libs
    # None found for: Calibre's GUI-only parts - Qt's test, EGLFS and Wayland shell plugins, text-to-speech, sound
    grep 'not found' ${BUILD_PATH}/ldd.txt | awk '{ print $1 }' | sort -u > ${BUILD_PATH}/not_found || true
    cat ${BUILD_PATH}/not_found

    while read -r lib; do
        cp -L "${lib}" "${RUNTIME}/$(basename "${lib}")"
    done < ${BUILD_PATH}/system_libs
    cp -L /lib64/ld-linux-x86-64.so.2 ${RUNTIME}/

    # The runtime's libraries find each other, not the NAS's - also when loaded through a link from elsewhere (e.g.
    # Wand's ImageMagick in magick/lib), where their own folder ($ORIGIN) would be the link's
    for lib in ${RUNTIME}/*; do
        [ "$(basename "${lib}")" = ld-linux-x86-64.so.2 ] || patchelf --set-rpath "\$ORIGIN:${RUNTIME}" "${lib}"
    done
}

# Every program starts with the runtime's loader, and every program and library also looks in the runtime
function patch_app() {
    while read -r file; do
        if readelf -l "${file}" 2>/dev/null | grep -q 'Requesting program interpreter'; then
            patchelf --set-interpreter ${RUNTIME}/ld-linux-x86-64.so.2 "${file}"
        fi
        patchelf --add-rpath ${RUNTIME} "${file}"
    done < ${BUILD_PATH}/elfs
}

# Checks: every program uses the runtime's loader, nothing needs a newer glibc than the runtime's, and the parts work
function check_app() {
    local found=0 version

    while read -r file; do
        if readelf -l "${file}" 2>/dev/null | grep -q 'Requesting program interpreter' \
            && [ "$(patchelf --print-interpreter "${file}")" != "${RUNTIME}/ld-linux-x86-64.so.2" ]; then
            echo "${file} doesn't use the runtime's loader"
            found=1
        fi

        for version in $(objdump -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${RUNTIME_GLIBC#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(app_elfs)
    [ ${found} = 0 ]
    # To a file: with head reading only its first line, Calibre would fail writing the rest
    ${APP}/calibre/ebook-convert --version > ${BUILD_PATH}/calibre-version.txt
    head -n 1 ${BUILD_PATH}/calibre-version.txt
    MAGICK_HOME=${APP}/magick ${APP}/python/bin/python3 -c "import calibreweb, wand.image, magic, lxml, comicapi; print('Calibre-Web imports')"
    ${APP}/kepubify-linux-64bit --version
    ${APP}/bin/gs --version

    # Nothing may differ only in case: a Windows drive holding the repository can't store that
    if [ -n "$(find ${APP} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${APP} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        return 1
    fi
}

function run() {
    # Clean start
    rm -rf ${BUILD_PATH} ${APP}
    mkdir -p ${BUILD_PATH} ${APP}

    get_calibre
    get_calibre_web
    get_kepubify
    get_imaging
    build_runas
    build_runtime
    patch_app
    check_app

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${APP}/. ${OUTPUT_PATH}/
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages /data/static/calibre-web/requirements.txt
}

run
