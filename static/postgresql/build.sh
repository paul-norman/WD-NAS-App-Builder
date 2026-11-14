#!/bin/bash

# PostgreSQL for the NAS, built on Debian Bullseye (the NAS's own Debian version), with OpenSSL 3.5 LTS built from
# source and the other libraries it uses (ICU, LZ4, Zstandard, zlib, readline, libuuid) bundled next to it - the NAS's
# system is stripped down, so it isn't relied on for anything beyond glibc and libstdc++. Every program and library
# finds the bundled ones through its own location ($ORIGIN), and PostgreSQL finds its files relative to its programs
# too, so the whole tree can live anywhere (the app's folder). Extensions included besides PostgreSQL's own (contrib):
# PostGIS (geometry / geography and topology - no rasters, which need GDAL), with GEOS and PROJ built from source and
# GMP bundled, pgvector, pg_cron, pg_partman and pgaudit.
#
# The ARM models: armhf.sh builds the same versions with clang and LLD (laid out for their kernels' large memory pages),
# against Alpine's static ARM libraries - with its own musl, which PostgreSQL's extensions need to be loaded - inside the
# Dockerfile's Alpine stage (/armhf-root, with chroot). It's checked here: its layout (ci/check_arm_pages.py), then with
# QEMU's emulator - a new cluster, the server, PostGIS (a coordinate transform), pgvector, pgcrypto.

set -e
set -o pipefail
set -x

VERSION=18.7
SHA256=441dfae4280cae3e0425e5f876f80559fb0731c140f1aae22b3e5a54d0411bfd
OPENSSL_VERSION=3.5.9
GEOS_VERSION=3.15.0
GEOS_SHA256=d5e5192a686d065eaed082de14dd26244c5c8e02bff16b2c6cce3265f648e00e
PROJ_VERSION=9.9.0
PROJ_SHA256=791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3
POSTGIS_VERSION=3.7.0
POSTGIS_SHA256=832bbf50f2b6f57fab053bc9676b3bfe641e5bf966cdcb28c7926f8d4b3c5e04
PGVECTOR_VERSION=0.8.7
PGVECTOR_SHA256=cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85
PG_CRON_VERSION=1.6.8
PG_CRON_SHA256=c19ab9bb35406c60fb51ecda993737c083850abe424acb6c1030439d00a1f8e4
PG_PARTMAN_VERSION=5.5.0
PG_PARTMAN_SHA256=a3f100ae871677f0012579f58542c174900297f664a4ad2be0256e7ee5e33502
PGAUDIT_VERSION=18.0
PGAUDIT_SHA256=988e8afeda320ebe0a3e632ef6b6bce5d3a08346c2e100a173a585c9521d1fa5
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
# The ARM build's own C library (musl - laid out for the ARM models' large memory pages) and libuuid (util-linux's), as
# their releases publish them (util-linux's in kernel.org's signed sha256sums.asc)
MUSL_VERSION=1.2.6
MUSL_SHA256=d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a
UTIL_LINUX_VERSION=2.41.6
UTIL_LINUX_SHA256=e596083744e746be7d2823b62b43f4418dd7bf56303b4dc09e6fe8112fe3d7ed
# ...and LZ4 and protobuf-c (Alpine's static ones are GCC link-time optimisation code): their releases (LZ4's as its
# .sha256 publishes it), the versions Alpine has
LZ4_VERSION=1.10.0
LZ4_SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
PROTOBUF_C_VERSION=1.5.2
PROTOBUF_C_SHA256=e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24
# ...and GMP (PostGIS's; Alpine has no static one) - static/php's pin
GMP_VERSION=6.3.0
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
# The architectures built (each into packages/static/postgresql/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
# A prefix containing "pgsql", so that PostgreSQL's share and lib folders are share/ and lib/
PREFIX=/usr/local/pgsql
OUTPUT_ROOT=/data/packages/static/postgresql/${VERSION}
OUTPUT_PATH=${OUTPUT_ROOT}/amd64
# The ARM build environment (the Dockerfile's Alpine stage), and where the ARM build is made: the app's folder on the
# NAS, as its programs find their loader by its full path
ARM_ROOT=/armhf-root
ARM_FINAL=/mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql

# The NAS's own libraries (everything else a program needs is bundled)
SYSTEM_LIBS='libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libstdc++.so.6 libgcc_s.so.1 ld-linux-x86-64.so.2'

function build_openssl() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl-${OPENSSL_VERSION}.tar.gz "${OPENSSL_SHA256}"
    tar -xzf openssl-${OPENSSL_VERSION}.tar.gz
    cd openssl-${OPENSSL_VERSION}
    ./Configure --prefix=${PREFIX} --libdir=lib shared no-tests no-docs
    make -j "$(nproc)"
    make install_sw
}

function build_postgresql() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.bz2" \
        postgresql-${VERSION}.tar.bz2 "${SHA256}"
    tar -xjf postgresql-${VERSION}.tar.bz2
    cd postgresql-${VERSION}
    ./configure --prefix=${PREFIX} --with-openssl --with-icu --with-lz4 --with-zstd --with-uuid=e2fs --with-readline \
        --with-includes=${PREFIX}/include --with-libraries=${PREFIX}/lib
    make -j "$(nproc)"
    make install
    # The usual extensions (pgcrypto, uuid-ossp, pg_trgm, hstore, citext...)
    make -C contrib -j "$(nproc)"
    make -C contrib install
}

# Downloads and unpacks a source archive after checking its checksum: $1 = URL, $2 = SHA-256, $3 = folder to unpack into
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" source.tar "$2"
    mkdir -p "$3"
    tar -xf source.tar -C "$3" --strip-components=1
    rm source.tar
}

# PostGIS's libraries: GEOS (geometry operations) and PROJ (coordinate systems, with its database of them - no network
# grids or TIFF)
function build_geos_proj() {
    fetch "https://github.com/libgeos/geos/releases/download/${GEOS_VERSION}/geos-${GEOS_VERSION}.tar.bz2" ${GEOS_SHA256} geos
    cmake -S ${BUILD_PATH}/geos -B ${BUILD_PATH}/geos/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF
    cmake --build ${BUILD_PATH}/geos/build -j "$(nproc)" --target install

    fetch "https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz" ${PROJ_SHA256} proj
    cmake -S ${BUILD_PATH}/proj -B ${BUILD_PATH}/proj/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF
    cmake --build ${BUILD_PATH}/proj/build -j "$(nproc)" --target install
}

# The extensions, built against this PostgreSQL (pg_config) and installed into it
function build_extensions() {
    export PATH="${PREFIX}/bin:${PATH}"

    fetch "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" ${POSTGIS_SHA256} postgis
    cd ${BUILD_PATH}/postgis
    LDFLAGS="-L${PREFIX}/lib" CPPFLAGS="-I${PREFIX}/include" ./configure --with-pgconfig=${PREFIX}/bin/pg_config \
        --with-geosconfig=${PREFIX}/bin/geos-config --with-projdir=${PREFIX} --without-raster --with-protobuf
    make -j "$(nproc)"
    make install

    # Pgvector builds for the build machine's CPU by default - OPTFLAGS="" keeps it to plain x86-64, for the NAS's
    fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" ${PGVECTOR_SHA256} pgvector
    make -C ${BUILD_PATH}/pgvector OPTFLAGS='' PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" ${PG_CRON_SHA256} pg_cron
    make -C ${BUILD_PATH}/pg_cron PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/pgpartman/pg_partman/archive/refs/tags/v${PG_PARTMAN_VERSION}.tar.gz" ${PG_PARTMAN_SHA256} pg_partman
    make -C ${BUILD_PATH}/pg_partman PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install

    fetch "https://github.com/pgaudit/pgaudit/archive/refs/tags/${PGAUDIT_VERSION}.tar.gz" ${PGAUDIT_SHA256} pgaudit
    make -C ${BUILD_PATH}/pgaudit USE_PGXS=1 PG_CONFIG=${PREFIX}/bin/pg_config -j "$(nproc)" install
}

# A tiny helper to run PostgreSQL's programs as the postgres user (PostgreSQL refuses to run as root, and the NAS has no
# su): drops root's groups, switches to the given IDs, checks the switch worked, then runs the program. Fully static
function build_runas() {
    cd ${BUILD_PATH}
    cat > pg_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	if (argc < 4) {
		fprintf(stderr, "Usage: pg_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (uid == 0 || setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0 || getuid() != uid || geteuid() != uid) {
		perror("pg_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("pg_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o pg_runas pg_runas.c
    strip pg_runas
}

# Copies the libraries each program needs (beyond the NAS's own) next to them, and points every program and library at
# them through its own location
function bundle() {
    mkdir -p ${OUTPUT_PATH}
    cp -r ${PREFIX}/bin ${PREFIX}/lib ${PREFIX}/share ${OUTPUT_PATH}/
    rm -rf ${OUTPUT_PATH}/lib/pkgconfig ${OUTPUT_PATH}/lib/cmake ${OUTPUT_PATH}/bin/geos-config ${OUTPUT_PATH}/lib/*.a ${OUTPUT_PATH}/lib/engines-3 ${OUTPUT_PATH}/lib/ossl-modules ${OUTPUT_PATH}/lib/pgxs

    # PostgreSQL's extensions are in lib/ too, next to the libraries
    for elf in ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/*.so*; do
        [ -L "${elf}" ] || ! file "${elf}" | grep -q ELF && continue
        ldd "${elf}" | awk '/=> \// { print $1, $3 }' | while read -r name path; do
            case " $(echo ${SYSTEM_LIBS}) " in *" ${name} "*) continue ;; esac
            [ -e "${OUTPUT_PATH}/lib/${name}" ] || cp -L "${path}" "${OUTPUT_PATH}/lib/${name}"
        done
    done
    strip --strip-unneeded ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/*.so* 2>/dev/null || true

    for elf in ${OUTPUT_PATH}/bin/*; do file "${elf}" | grep -q ELF && patchelf --set-rpath '$ORIGIN/../lib' "${elf}"; done

    for elf in ${OUTPUT_PATH}/lib/*.so*; do [ -L "${elf}" ] || patchelf --set-rpath '$ORIGIN' "${elf}"; done
}

# Builds PostgreSQL and its extensions for the ARM models with armhf.sh, in the Alpine stage (with chroot: its own /dev
# entries made first, as the builds need them), into ${BUILD_PATH}/armhf-out (until it's checked) - and lists the
# Alpine packages whose static libraries it may have linked in, for their sources (ci/sources.py reads it as it reads
# the survey's distro.tsv).
function build_arm() {
    local work=${ARM_ROOT}/work
    local device

    rm -rf ${work}
    mkdir -p ${work}
    cd ${work}
    sh /data/static/fetch.sh "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.bz2" \
        postgresql.tar.bz2 "${SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/libgeos/geos/releases/download/${GEOS_VERSION}/geos-${GEOS_VERSION}.tar.bz2" geos.tar.bz2 \
        "${GEOS_SHA256}"
    sh /data/static/fetch.sh "https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz" proj.tar.gz "${PROJ_SHA256}"
    sh /data/static/fetch.sh "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" \
        postgis.tar.gz "${POSTGIS_SHA256}"
    sh /data/static/fetch.sh "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
        pgvector.tar.gz "${PGVECTOR_SHA256}"
    sh /data/static/fetch.sh "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" \
        pg_cron.tar.gz "${PG_CRON_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/pgpartman/pg_partman/archive/refs/tags/v${PG_PARTMAN_VERSION}.tar.gz" pg_partman.tar.gz \
        "${PG_PARTMAN_SHA256}"
    sh /data/static/fetch.sh "https://github.com/pgaudit/pgaudit/archive/refs/tags/${PGAUDIT_VERSION}.tar.gz" \
        pgaudit.tar.gz "${PGAUDIT_SHA256}"
    sh /data/static/fetch.sh "https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz" musl.tar.gz "${MUSL_SHA256}"
    sh /data/static/fetch.sh \
        "https://www.kernel.org/pub/linux/utils/util-linux/v${UTIL_LINUX_VERSION%.*}/util-linux-${UTIL_LINUX_VERSION}.tar.xz" \
        util-linux.tar.xz "${UTIL_LINUX_SHA256}"
    sh /data/static/fetch.sh "https://github.com/lz4/lz4/releases/download/v${LZ4_VERSION}/lz4-${LZ4_VERSION}.tar.gz" \
        lz4.tar.gz "${LZ4_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/protobuf-c/protobuf-c/releases/download/v${PROTOBUF_C_VERSION}/protobuf-c-${PROTOBUF_C_VERSION}.tar.gz" \
        protobuf-c.tar.gz "${PROTOBUF_C_SHA256}"
    sh /data/static/fetch.sh "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz" gmp.tar.xz "${GMP_SHA256}"
    cp /data/static/postgresql/armhf.sh ${work}/

    for device in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9'; do
        set -- ${device}
        [ -e ${ARM_ROOT}/dev/$1 ] || mknod -m 666 ${ARM_ROOT}/dev/$1 c $2 $3
    done

    # (on a failure, the builds' configure logs are kept beside the output, to look into: packages/static/postgresql/
    # <version>/armhf-logs)
    if ! chroot ${ARM_ROOT} /usr/bin/env VERSION=${VERSION} /bin/bash /work/armhf.sh; then
        rm -rf ${OUTPUT_ROOT}/armhf-logs
        mkdir -p ${OUTPUT_ROOT}/armhf-logs
        find ${work} -maxdepth 3 \( -name config.log -o -name CMakeError.log \) | while read -r log; do
            cp "${log}" "${OUTPUT_ROOT}/armhf-logs/$(echo "${log#${work}/}" | tr / _)"
        done

        exit 1
    fi

    rm -rf ${OUTPUT_ROOT}/armhf-logs

    rm -rf ${BUILD_PATH}/armhf-out
    mkdir -p ${BUILD_PATH}/armhf-out
    cp -a ${ARM_ROOT}${ARM_FINAL}/. ${BUILD_PATH}/armhf-out/
    mkdir -p ${OUTPUT_PATH}.sources
    rm -rf ${OUTPUT_PATH}.sources/armhf-debian
    alpine_packages ${ARM_ROOT}/armv7 ${ARM_ROOT}/etc/os-release > ${OUTPUT_PATH}.sources/armhf-distro.tsv
    cd ${BUILD_PATH}
    rm -rf ${work}
    du -sh ${BUILD_PATH}/armhf-out
}

# Lists an Alpine system's packages holding static libraries, as the survey lists an Alpine stage's (ci/survey_inside.sh).
#
# $1 root    The Alpine system's folder
# $2 release Its Alpine release's os-release file (the ARM system has none of its own: the stage's, the same release)
#
# Prints a line per package: os, its version, stage (armhf), source package, version, license, why (static), aports
# commit and package name - tab separated
function alpine_packages() {
    local osv

    osv="$(sed -n 's/^VERSION_ID=//p' "$2")"
    awk -v osv="${osv}" '
        function flush() {
            if (name != "" && static) {
                printf "alpine\t%s\tarmhf\t%s\t%s\t%s\tstatic\t%s\t%s\n", osv, origin, version, license, commit, name
            }
            name = ""; version = ""; origin = ""; commit = ""; license = ""; folder = ""; static = 0
        }
        /^$/ { flush(); next }
        /^P:/ { name = substr($0, 3) }
        /^V:/ { version = substr($0, 3) }
        /^o:/ { origin = substr($0, 3) }
        /^c:/ { commit = substr($0, 3) }
        /^L:/ { license = substr($0, 3) }
        /^F:/ { folder = substr($0, 3) }
        /^R:/ { if (substr($0, 3) ~ /\.a$/ && folder ~ /^(usr\/)?lib/) static = 1 }
        END { flush() }
    ' "$1/lib/apk/db/installed"
}

# Checks the ARM build: laid out for the ARM models' large memory pages (ci/check_arm_pages.py), then with QEMU's
# emulator (as a Cortex-A9, the ARM models' processors' kind) in the Alpine stage (with chroot), at the app's path on
# the NAS (where its programs find musl's loader): pg_runas refusing root, then - as the postgres user, through it - a
# new cluster (as the app makes it), the server, and PostGIS (the coordinate transform checked on the NAS), pgvector,
# pgcrypto and pg_trgm in it. Its programs are run through scripts calling QEMU, so that PostgreSQL's own programs can
# run each other as on the NAS.
function check_arm() {
    local final=${ARM_ROOT}${ARM_FINAL}
    local program

    python3 /data/ci/check_arm_pages.py ${BUILD_PATH}/armhf-out
    rm -rf ${final} ${ARM_ROOT}/check
    mkdir -p "$(dirname ${final})" ${ARM_ROOT}/check
    cp -a ${BUILD_PATH}/armhf-out ${final}
    mv ${final}/bin ${final}/bin-arm
    mkdir ${final}/bin

    for program in ${final}/bin-arm/*; do
        # (-0: the program sees the script's path as its own, so that it finds its siblings - the scripts - beside it)
        printf '#!/bin/sh\nexec qemu-arm -cpu cortex-a9 -0 "$0" %s "$@"\n' "${ARM_FINAL}/bin-arm/$(basename ${program})" \
            > ${final}/bin/$(basename ${program})
        chmod 755 ${final}/bin/$(basename ${program})
    done

    cat > ${ARM_ROOT}/check/check.sh <<'CHECK'
set -e
set -o pipefail
set -x
final=/mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql
data=/check/data
socket=/check/sock
runas="${final}/bin/pg_runas 70 70"
export PROJ_DATA=${final}/share/proj
${final}/bin/postgres --version | grep "(PostgreSQL) ${VERSION}" > /dev/null

if ${final}/bin/pg_runas 0 0 /bin/true 2> /dev/null; then
    echo 'pg_runas ran something as root'

    exit 1
fi

# (the postgres user, ID 70, as the app adds it on the NAS - initdb looks itself up)
grep -q '^postgres:' /etc/passwd || echo 'postgres:x:70:70:PostgreSQL:/check:/sbin/nologin' >> /etc/passwd
grep -q '^postgres:' /etc/group || echo 'postgres:x:70:' >> /etc/group
mkdir -p ${data} ${socket}
chown 70:70 ${data} ${socket}
${runas} ${final}/bin/initdb -D ${data} -U postgres --auth=trust --locale-provider=builtin --builtin-locale=C.UTF-8
${runas} ${final}/bin/pg_ctl -D ${data} -l ${data}/server.log -w -t 300 \
    -o "-c listen_addresses='' -c unix_socket_directories=${socket}" start
psql="${final}/bin/psql -h ${socket} -U postgres -X -A -t -v ON_ERROR_STOP=1"
${psql} -c 'SELECT version()' | grep "PostgreSQL ${VERSION}" > /dev/null
${psql} -c 'CREATE EXTENSION postgis; CREATE EXTENSION vector; CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm'
${psql} -c "SELECT ST_AsText(ST_SnapToGrid(ST_Transform(ST_SetSRID(ST_MakePoint(-0.1276, 51.5072), 4326), 27700), 1))" \
    | grep 'POINT(530' > /dev/null
${psql} -c "SELECT '[1,2,3]'::vector <-> '[4,6,3]'::vector" | grep '^5$' > /dev/null
${psql} -c "SELECT encode(digest('abc', 'sha256'), 'hex')" | grep '^ba7816bf' > /dev/null
${psql} -c "SELECT similarity('postgres', 'postgis') > 0.3" | grep '^t$' > /dev/null
${runas} ${final}/bin/pg_ctl -D ${data} -w -t 120 stop
CHECK
    chroot ${ARM_ROOT} /usr/bin/env VERSION=${VERSION} /bin/bash /check/check.sh
    rm -rf ${final} ${ARM_ROOT}/check
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    # The Intel build (unless it's already made: e.g. only the ARM build is missing)
    if [ -x ${OUTPUT_PATH}/bin/postgres ] && [ -x ${OUTPUT_PATH}/bin/pg_runas ]; then
        echo "PostgreSQL ${VERSION} (amd64) is already built: ${OUTPUT_PATH}"
    else
        build_openssl
        build_geos_proj
        build_postgresql
        build_extensions
        rm -rf ${OUTPUT_PATH}
        bundle
        build_runas
        cp ${BUILD_PATH}/pg_runas ${OUTPUT_PATH}/bin/
        du -sh ${OUTPUT_PATH}
        ${OUTPUT_PATH}/bin/postgres --version
    fi

    build_arm
    check_arm
    # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
    rm -rf ${OUTPUT_ROOT}/armhf
    mkdir -p ${OUTPUT_ROOT}/armhf
    cp -a ${BUILD_PATH}/armhf-out/. ${OUTPUT_ROOT}/armhf/

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
