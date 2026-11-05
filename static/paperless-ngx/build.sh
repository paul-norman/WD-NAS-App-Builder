#!/bin/bash

# Prepares Paperless-ngx for the NAS, with everything it uses:
#  - Paperless-ngx (its web server, consumer, task worker and scheduler, and its ready-made web interface), in its own
#    Python (a portable build), with the packages its release pins - except those for local AI models and other
#    databases (below)
#  - the document tools its OCR uses: Tesseract (English and German, plus script detection), Ghostscript, unpaper,
#    pngquant and qpdf; poppler's pdftoppm / pdftotext; libmagic; fonts for text files' thumbnails. unpaper is built
#    here, against a small ffmpeg for the image formats OCRmyPDF gives it (PNG, PNM): Debian's brings all of ffmpeg,
#    with its video encoders and graphics libraries (over 100MB)
#  - pl_runas: switches to Paperless's own user (the NAS has no su or similar) before running it
#
# These need a newer glibc than the NAS's 2.31, so the app brings its own: Debian Trixie's glibc (2.41) and the other
# libraries these programs expect from a system, in binaries/runtime. Every program here is patched to start with that
# runtime's loader, and every program and library to look in it first - nothing else on the NAS is affected (WD's own
# programs keep the NAS's glibc). The loader is found by its full path, so everything is prepared exactly where the app
# lives on the NAS (Nas_Prog on the first volume) - as for Calibre-Web

set -e
set -o pipefail
set -x

VERSION=3.4.2
PAPERLESS_SHA256=599be82cd8fc184436b757f9b193101fb71a90bf0facf5695dcda43152fffc85
# Left out of Paperless's pinned packages: PyTorch and the local AI embedding models (sentence-transformers - over 1GB;
# Paperless only imports them for its optional "HuggingFace" embedding backend: its AI features work with OpenAI-like
# or Ollama servers), and the MariaDB / PostgreSQL drivers (the app uses SQLite). Packages only these need go too
EXCLUDED='torch sentence-transformers transformers llama-index-embeddings-huggingface mysqlclient psycopg psycopg-c
    psycopg-pool'
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
UNPAPER_VERSION=7.0.0
UNPAPER_SHA256=601b64b030edb4a734510a7bdcab371c7a33c4501f9a0e231e3d326df50e2313
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
# The runtime's glibc: nothing may need a newer one
RUNTIME_GLIBC=2.41

# Where the app's binaries are on the NAS
APP=/mnt/HD/HD_a2/Nas_Prog/paperless-ngx/binaries
RUNTIME=${APP}/runtime
BUILD_PATH=/build
DEPS_PATH=${BUILD_PATH}/deps
OUTPUT_PATH=/data/packages/static/paperless-ngx/${VERSION}/amd64

# Downloads a file and checks it against its SHA256 (with the mirror to fall back on).
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$@"
}

# Paperless's pinned packages (requirements.txt, with every file's checksum), without the excluded ones - and without
# any package that only they need (by the "# via" lines uv writes for each package).
function filter_requirements() {
    ${APP}/python/bin/python3 - "$1" "$2" ${EXCLUDED} <<'PY'
import re
import sys

source, target, excluded = sys.argv[1], sys.argv[2], set(sys.argv[3:])
blocks, header, current = {}, [], None

for line in open(source, encoding="utf-8"):
    match = re.match(r"^([A-Za-z0-9._-]+)==", line)

    if match:
        current = match.group(1).lower()
        blocks.setdefault(current, []).append(line)
    elif current is None:
        header.append(line)
    else:
        blocks[current].append(line)


def needed_by(lines):
    """The packages a block's "# via" lines name (empty for direct requirements)."""
    names, via = set(), False

    for line in lines:
        text = line.strip()

        if text.startswith("# via"):
            via = True
            rest = text[len("# via"):].strip()

            if rest:
                names.add(rest.split()[0].lower())
        elif via and text.startswith("#   "):
            names.add(text[1:].strip().split()[0].lower())

    return names


changed = True

while changed:
    changed = False

    for name, lines in blocks.items():
        users = needed_by(lines)

        if name not in excluded and users and users <= excluded:
            excluded.add(name)
            changed = True

with open(target, "w", encoding="utf-8") as out:
    out.writelines(line for line in header if not line.startswith("--"))

    for name, lines in blocks.items():
        if name not in excluded:
            out.writelines(lines)

print("left out:", " ".join(sorted(excluded)))
PY
}

function get_paperless() {
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz -C ${APP}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    local uv=${BUILD_PATH}/uv-x86_64-unknown-linux-musl/uv

    fetch "https://github.com/paperless-ngx/paperless-ngx/releases/download/v${VERSION}/paperless-ngx-v${VERSION}.tar.xz" \
        paperless.tar.xz ${PAPERLESS_SHA256}
    tar -xJf paperless.tar.xz
    mkdir -p ${APP}/paperless
    cp -a paperless-ngx/src paperless-ngx/static ${APP}/paperless/
    # Its web interface's sources (its ready-made copy is in static) and its tests aren't needed to run it
    rm -rf ${APP}/paperless/src/documents/static
    find ${APP}/paperless/src -type d -name tests -prune -exec rm -rf {} +
    dedupe_static
    filter_requirements paperless-ngx/requirements.txt requirements-nas.txt

    # The lock is complete (every package pinned, with its checksums), so it's installed as it is
    ${uv} pip install --python ${APP}/python/bin/python3 --break-system-packages --require-hashes \
        -r requirements-nas.txt --no-deps
    ${APP}/python/bin/python3 -m compileall -q ${APP}/python/lib/python3.14/site-packages ${APP}/paperless/src \
        > /dev/null || true
    # Not needed by a server: the terminal database (its folders also differ only in case, which a Windows drive holding
    # the repository can't store), IDLE and pip
    rm -rf ${APP}/python/share/terminfo ${APP}/python/lib/python3*/idlelib ${APP}/python/bin/idle3*
    rm -rf ${APP}/python/lib/python3*/site-packages/pip ${APP}/python/lib/python3*/site-packages/pip-* ${APP}/python/bin/pip*
    # Nor the packages' own tests
    find ${APP}/python/lib/python3*/site-packages -type d -name tests -prune -exec rm -rf {} +
}

# Its web interface comes in 40 languages, each a full copy: most files (fonts, images, PDF viewer...) are the same in
# every one. Each set of identical files is kept once, the others becoming links to it
function dedupe_static() {
    ${APP}/python/bin/python3 - ${APP}/paperless/static <<'PY'
import collections
import hashlib
import os
import sys

root = sys.argv[1]
copies = collections.defaultdict(list)

for folder, _, files in os.walk(root):
    for name in files:
        path = os.path.join(folder, name)

        if not os.path.islink(path):
            with open(path, "rb") as handle:
                copies[hashlib.sha256(handle.read()).hexdigest()].append(path)

saved = 0

for paths in copies.values():
    # The English one is kept, if it's one of them
    paths.sort(key=lambda path: ("/en-US/" not in path, path))

    for path in paths[1:]:
        saved += os.path.getsize(path)
        os.remove(path)
        os.symlink(os.path.relpath(paths[0], os.path.dirname(path)), path)

print(f"web interface: {saved // 1048576}MB of identical files linked")
PY
}

# unpaper, against a small static ffmpeg: reading and writing PNG and PNM images only (what OCRmyPDF gives it)
function build_unpaper() {
    fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.tar.xz ${FFMPEG_SHA256} \
        "https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_${FFMPEG_VERSION}.orig.tar.xz" \
        "https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    tar -xf ffmpeg.tar.xz
    cd ffmpeg-${FFMPEG_VERSION}
    ./configure --prefix=${DEPS_PATH} --disable-shared --enable-static --disable-programs --disable-doc \
        --disable-everything --disable-autodetect --disable-network --disable-x86asm --disable-avdevice \
        --disable-avfilter --disable-swscale --disable-swresample --enable-protocol=file --enable-zlib \
        --enable-demuxer=image2,image_pbm_pipe,image_pgm_pipe,image_ppm_pipe,image_pam_pipe,image_png_pipe \
        --enable-muxer=image2 --enable-decoder=pbm,pgm,pgmyuv,ppm,pam,png --enable-encoder=pbm,pgm,ppm,pam,png \
        --enable-parser=pnm,png
    make -j"$(nproc)"
    make install

    fetch "https://github.com/unpaper/unpaper/archive/refs/tags/unpaper-${UNPAPER_VERSION}.tar.gz" unpaper.tar.gz \
        ${UNPAPER_SHA256}
    tar -xzf unpaper.tar.gz
    cd unpaper-unpaper-${UNPAPER_VERSION}
    # Its own build (Meson) also needs Sphinx, for its manual page: the program alone is five C files
    sed "s/@version@/${UNPAPER_VERSION}/" version.h.in > version.h
    gcc -std=c11 -O2 -D_POSIX_C_SOURCE=200809L -o unpaper file.c imageprocess.c parse.c tools.c unpaper.c \
        $(PKG_CONFIG_PATH=${DEPS_PATH}/lib/pkgconfig pkg-config --cflags --libs --static libavformat libavcodec libavutil) -lm
    strip unpaper
    install -m 755 unpaper ${APP}/bin/unpaper
}

# The document tools (in bin), Tesseract's language data, Ghostscript's resources and colour profiles, libmagic's file
# type database and the fonts
function get_tools() {
    mkdir -p ${APP}/bin ${APP}/tessdata ${APP}/ghostscript ${APP}/fonts ${RUNTIME}
    local tool

    for tool in tesseract gs pngquant qpdf pdftoppm pdftotext pdfinfo jbig2dec; do
        cp -L "$(command -v ${tool})" ${APP}/bin/
    done

    cp /usr/share/tesseract-ocr/5/tessdata/eng.traineddata /usr/share/tesseract-ocr/5/tessdata/deu.traineddata \
        /usr/share/tesseract-ocr/5/tessdata/osd.traineddata ${APP}/tessdata/
    cp -r /usr/share/tesseract-ocr/5/tessdata/configs ${APP}/tessdata/ 2>/dev/null || true
    # Its resources with their fonts themselves: Debian's Resource/Font holds links to its URW fonts package. (Some links
    # point at fonts that aren't installed, e.g. a CJK fallback: those are skipped.) The standard fonts must be there
    cp -rL /usr/share/ghostscript/*/Resource /usr/share/ghostscript/*/lib ${APP}/ghostscript/ 2>/dev/null || true
    [ -f ${APP}/ghostscript/Resource/Font/NimbusSans-Regular ] && [ ! -L ${APP}/ghostscript/Resource/Font/NimbusSans-Regular ]
    cp -rL /usr/share/ghostscript/fonts ${APP}/ghostscript/ 2>/dev/null || true
    cp -r /usr/share/color/icc ${APP}/icc
    cp -L /usr/lib/file/magic.mgc ${APP}/magic.mgc
    cp -L /usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf ${APP}/fonts/
    # Fontconfig's settings (Ghostscript asks it for fonts): the app's own fonts, its cache in the user's home
    printf '<?xml version="1.0"?>\n<fontconfig>\n  <dir>%s</dir>\n  <dir>%s</dir>\n  <cachedir prefix="xdg">fontconfig</cachedir>\n</fontconfig>\n' \
        "${APP}/fonts" "${APP}/ghostscript/Resource/Font" > ${APP}/fonts/fonts.conf
    # Python's magic loads libmagic itself - nothing links to it - so it's placed in the runtime by name
    cp -L /usr/lib/x86_64-linux-gnu/libmagic.so.1 ${RUNTIME}/
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > pl_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: pl_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("pl_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("pl_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o pl_runas pl_runas.c
    strip pl_runas
    install -m 755 pl_runas ${APP}/pl_runas
}

# Every ELF file in the app, except the runtime itself and the static programs
function app_elfs() {
    find ${APP} -path ${RUNTIME} -prune -o -type f -print0 | xargs -0 file | grep -E ': *ELF' \
        | grep -v 'statically linked' | cut -d: -f1
}

# The runtime: every library these programs resolve to outside the app, plus glibc's loader
function build_runtime() {
    mkdir -p ${RUNTIME}
    app_elfs > ${BUILD_PATH}/elfs
    { cat ${BUILD_PATH}/elfs; ls ${RUNTIME}/*; } | xargs -d '\n' -n 50 ldd > ${BUILD_PATH}/ldd.txt 2>/dev/null || true
    awk '$2 == "=>" && $3 ~ /^\// { print $3 }' ${BUILD_PATH}/ldd.txt | grep -v "^${APP}/" | sort -u \
        > ${BUILD_PATH}/system_libs
    grep 'not found' ${BUILD_PATH}/ldd.txt | awk '{ print $1 }' | sort -u > ${BUILD_PATH}/not_found || true
    cat ${BUILD_PATH}/not_found

    while read -r lib; do
        cp -L "${lib}" "${RUNTIME}/$(basename "${lib}")"
    done < ${BUILD_PATH}/system_libs
    cp -L /lib64/ld-linux-x86-64.so.2 ${RUNTIME}/

    # The runtime's libraries find each other, not the NAS's
    for lib in ${RUNTIME}/*; do
        [ "$(basename "${lib}")" = ld-linux-x86-64.so.2 ] || patchelf --set-rpath "\$ORIGIN:${RUNTIME}" "${lib}"
    done
}

# Every program starts with the runtime's loader, and every program and library also looks in the runtime. Libraries a
# Python wheel brings along (in its <package>.libs folder) also look in their own folder: they used to find each other
# through the RPATH of the module loading them, which patchelf turns into a RUNPATH - and that only covers the module's
# own libraries, not theirs (e.g. SciPy's libgfortran needs its libquadmath)
function patch_app() {
    while read -r file; do
        if readelf -l "${file}" 2>/dev/null | grep -q 'Requesting program interpreter'; then
            patchelf --set-interpreter ${RUNTIME}/ld-linux-x86-64.so.2 "${file}"
        fi

        case "${file}" in
            */site-packages/*.libs/*) patchelf --add-rpath '$ORIGIN' "${file}" ;;
        esac

        patchelf --add-rpath ${RUNTIME} "${file}"
    done < ${BUILD_PATH}/elfs
}

# Checks: every program uses the runtime's loader, nothing needs a newer glibc than the runtime's, and the parts work -
# down to OCR of a page made here
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

    # The tools, with nothing of the build machine's in their way: its own copies of their data are hidden (the NAS has
    # none), and they're given the app's, as pl_ctl.sh gives them
    local hidden

    for hidden in /usr/share/ghostscript /usr/share/tesseract-ocr /usr/share/color /usr/share/fonts /usr/share/poppler \
        /etc/ghostscript /var/lib/ghostscript /usr/lib/file /usr/share/file; do
        [ -e "${hidden}" ] && mv "${hidden}" "${hidden}.hidden"
    done

    local env="env -i PATH=${APP}/bin:${APP}/python/bin:/usr/bin:/bin TESSDATA_PREFIX=${APP}/tessdata
        GS_LIB=${APP}/ghostscript/Resource/Init:${APP}/ghostscript/lib:${APP}/ghostscript/Resource/Font MAGIC=${APP}/magic.mgc
        GS_OPTIONS=-sICCProfilesDir=${APP}/icc/ghostscript/ FONTCONFIG_FILE=${APP}/fonts/fonts.conf HOME=${BUILD_PATH}"
    ${env} tesseract --list-langs
    ${env} gs --version
    ${env} qpdf --version | head -n 1
    ${env} unpaper --version
    ${env} python3 -c "import ocrmypdf, pikepdf, magic, granian, celery, django, sklearn, tantivy; print('imports', ocrmypdf.__version__)"

    # A page with text (made by Ghostscript), cleaned by unpaper, OCRed by OCRmyPDF (as Paperless does): its text must
    # come back
    cd ${BUILD_PATH}
    printf '%%!PS\n/Helvetica findfont 40 scalefont setfont 72 600 moveto (Paperless on the NAS) show showpage\n' > page.ps
    ${env} gs -q -dNOPAUSE -dBATCH -sDEVICE=png16m -r150 -sOutputFile=page.png page.ps
    ${env} python3 -m ocrmypdf --image-dpi 150 --clean --output-type pdfa -l eng page.png page.pdf
    ${env} pdftotext page.pdf - | grep -q 'Paperless on the NAS'

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

    get_paperless
    get_tools
    build_unpaper
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

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
