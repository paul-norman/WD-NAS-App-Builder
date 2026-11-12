#!/bin/bash

# MariaDB for the NAS: MariaDB's own Linux release (built for glibc 2.28+, the NAS has 2.31), checked against its
# published checksum, cut down to what a server needs (no test suite, Galera, or plugins needing libraries the NAS
# doesn't have) and stripped. Its server needs libsystemd only to tell systemd it's ready - which the NAS doesn't run -
# so a stand-in library is added, found through a fixed path (/usr/local/mysql/lib: the app links /usr/local/mysql to
# these files, which is also where MariaDB's release looks for its plugins, messages and character sets).
#
# The ARM models: MariaDB publishes no 32-bit ARM release, so armhf.sh compiles the same version from its source, fully
# static (clang and LLD, against Alpine's static ARM libraries in /armv7: laid out for the ARM models' large memory
# pages). It's checked here: its layout (ci/check_arm_pages.py), then with QEMU's emulator - a new database, the server,
# InnoDB, the client tools. (This image is Alpine: older QEMUs, and QEMU in a chroot, hang running its server.)

set -e
set -o pipefail
set -x

VERSION=11.8.9
SHA256=32f8871a2aa38b36aa418b7f4abc6fc0c6ef1ba5a45798cacb2afa52c8a6113b
# MariaDB's source, for the ARM build (its published SHA256: source/sha256sums.txt)
SOURCE_SHA256=2e015b7e91004142eda8b3a20d3ceb875cf2ae55e72603e7222cd497d4e56fc6
# The architectures built (each into packages/static/mariadb/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
OUTPUT_ROOT=/data/packages/static/mariadb/${VERSION}
OUTPUT_PATH=${OUTPUT_ROOT}/amd64
# Where the ARM build is made: the path the app links to MariaDB on the NAS
ARM_PREFIX=/usr/local/mysql

# The programs kept: the server, and the client tools for managing, backing up and upgrading it
PROGRAMS="mariadbd mariadb mariadb-admin mariadb-dump mariadb-import mariadb-check mariadb-show mariadb-upgrade
	mariadb-tzinfo-to-sql mariadb-backup my_print_defaults resolveip"

# Libraries the NAS has (anything else a plugin needs rules it out)
SYSTEM_LIBS="libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libstdc++.so.6 libgcc_s.so.1 libcrypt.so.1
	ld-linux-x86-64.so.2"

function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://archive.mariadb.org/mariadb-${VERSION}/bintar-linux-systemd-x86_64/mariadb-${VERSION}-linux-systemd-x86_64.tar.gz" \
        mariadb.tar.gz "${SHA256}"
    mkdir release
    tar -xzf mariadb.tar.gz -C release --strip-components=1
}

# The stand-in for libsystemd: the three functions MariaDB's server calls, doing nothing (as with no systemd) - needing
# no library at all (-nostdlib), so that it's built here (musl) for MariaDB's release (glibc)
function build_libsystemd() {
    cd ${BUILD_PATH}
    cat > libsystemd.c <<'C'
int sd_notify(int unset_environment, const char *state) { return 0; }
int sd_notifyf(int unset_environment, const char *format, ...) { return 0; }
int sd_listen_fds_with_names(int unset_environment, char ***names) { return 0; }
C
    cat > libsystemd.map <<'MAP'
LIBSYSTEMD_209 { global: sd_notify; sd_notifyf; local: *; };
LIBSYSTEMD_227 { global: sd_listen_fds_with_names; } LIBSYSTEMD_209;
MAP
    gcc -O2 -fPIC -shared -nostdlib -o libsystemd.so.0 -Wl,-soname,libsystemd.so.0 \
        -Wl,--version-script=libsystemd.map libsystemd.c

    if readelf -d libsystemd.so.0 | grep NEEDED; then
        echo 'The stand-in libsystemd needs a library'

        exit 1
    fi
}

function assemble() {
    release=${BUILD_PATH}/release
    mkdir -p ${OUTPUT_PATH}/bin ${OUTPUT_PATH}/lib/plugin ${OUTPUT_PATH}/scripts

    for program in ${PROGRAMS}; do
        cp ${release}/bin/${program} ${OUTPUT_PATH}/bin/
    done

    cp ${release}/scripts/mariadb-install-db ${OUTPUT_PATH}/scripts/
    cp -r ${release}/share ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/libsystemd.so.0 ${OUTPUT_PATH}/lib/

    # Only plugins that need nothing beyond the NAS's own libraries
    for plugin in ${release}/lib/plugin/*.so; do
        missing=''

        for lib in $(readelf -d "${plugin}" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
            case " $(echo ${SYSTEM_LIBS}) " in *" ${lib} "*) ;; *) missing="${missing} ${lib}" ;; esac
        done

        if [ -z "${missing}" ]; then
            cp "${plugin}" ${OUTPUT_PATH}/lib/plugin/
        else
            echo "Leaving out $(basename "${plugin}") (needs:${missing})"
        fi
    done

    strip ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/plugin/*.so ${OUTPUT_PATH}/lib/libsystemd.so.0
    # The server finds the stand-in libsystemd in /usr/local/mysql/lib
    patchelf --set-rpath /usr/local/mysql/lib ${OUTPUT_PATH}/bin/mariadbd
}

# Builds MariaDB for the ARM models with armhf.sh, into ${BUILD_PATH}/armhf-out (until it's checked) - and lists the
# Alpine packages whose static libraries it may have linked in, for their sources (ci/sources.py reads it as it reads
# the survey's distro.tsv).
function build_arm() {
    local work=/work

    rm -rf ${work}
    mkdir -p ${work}
    cd ${work}
    sh /data/static/fetch.sh "https://archive.mariadb.org/mariadb-${VERSION}/source/mariadb-${VERSION}.tar.gz" \
        mariadb.tar.gz "${SOURCE_SHA256}"
    VERSION=${VERSION} bash /data/static/mariadb/armhf.sh

    rm -rf ${BUILD_PATH}/armhf-out
    mkdir -p ${BUILD_PATH}/armhf-out
    cp -a ${ARM_PREFIX}/. ${BUILD_PATH}/armhf-out/
    mkdir -p ${OUTPUT_PATH}.sources
    rm -rf ${OUTPUT_PATH}.sources/armhf-debian
    alpine_packages /armv7 /etc/os-release > ${OUTPUT_PATH}.sources/armhf-distro.tsv
    cd ${BUILD_PATH}
    rm -rf ${work}
    du -sh ${BUILD_PATH}/armhf-out
}

# Lists an Alpine system's packages holding static libraries, as the survey lists an Alpine stage's (ci/survey_inside.sh).
#
# $1 root    The Alpine system's folder
# $2 release Its Alpine release's os-release file (the ARM system has none of its own: this image's, the same release)
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
# emulator (as a Cortex-A9, the ARM models' processors' kind), at the path the app links to it: each program runs, mariadb-install-db makes a new database, the
# server starts on it, stores and reads back data with InnoDB, mariadb-dump dumps it, and it shuts down cleanly. Its
# programs are run through scripts calling QEMU, so that MariaDB's own scripts can run them as on the NAS.
function check_arm() {
    local prefix=${ARM_PREFIX}
    local program

    # (a copy kept until it passes, to look into a failure: build_static.sh skips a build whose armhf folder isn't empty,
    # so it's kept beside it)
    rm -rf ${OUTPUT_ROOT}/armhf-unchecked
    cp -a ${BUILD_PATH}/armhf-out ${OUTPUT_ROOT}/armhf-unchecked
    python3 /data/ci/check_arm_pages.py ${BUILD_PATH}/armhf-out

    rm -rf ${prefix} /check
    cp -a ${BUILD_PATH}/armhf-out ${prefix}
    mv ${prefix}/bin ${prefix}/bin-arm
    mkdir -p ${prefix}/bin /check

    for program in ${prefix}/bin-arm/*; do
        printf '#!/bin/sh\nexec qemu-arm -cpu cortex-a9 %s "$@"\n' "${ARM_PREFIX}/bin-arm/$(basename ${program})" \
            > ${prefix}/bin/$(basename ${program})
        chmod 755 ${prefix}/bin/$(basename ${program})
    done

    cat > /check/check.sh <<'CHECK'
set -e
set -o pipefail
set -x
prefix=/usr/local/mysql
data=/check/data
socket=/check/mariadb.sock
${prefix}/bin/mariadbd --version > /check/version.txt
cat /check/version.txt
grep "Ver ${VERSION}-MariaDB" /check/version.txt > /dev/null
${prefix}/bin/mariadb-backup --version
${prefix}/scripts/mariadb-install-db --no-defaults --basedir=${prefix} --datadir=${data} --user=root \
    --auth-root-authentication-method=normal --skip-test-db
${prefix}/bin/mariadbd --no-defaults --basedir=${prefix} --datadir=${data} --user=root --socket=${socket} \
    --skip-networking --lc-messages-dir=${prefix}/share --character-sets-dir=${prefix}/share/charsets \
    --log-error=${data}/server.err &
client="${prefix}/bin/mariadb --no-defaults --socket=${socket} -uroot"
waited=0

until ${client} -e 'SELECT 1' > /dev/null 2>&1; do
    if [ ${waited} -ge 180 ]; then
        cat ${data}/server.err

        exit 1
    fi

    sleep 1
    waited=$((waited + 1))
done

${client} -N -e 'SELECT VERSION()' | grep "^${VERSION}-MariaDB" > /dev/null
${client} -e "CREATE DATABASE armtest CHARACTER SET utf8mb4; CREATE TABLE armtest.t (id INT PRIMARY KEY,
    v VARCHAR(20)) ENGINE=InnoDB; INSERT INTO armtest.t VALUES (1, 'Grüße vom ARM')"
${client} -N -e 'SELECT v FROM armtest.t WHERE id = 1' | grep 'Grüße vom ARM' > /dev/null
${client} -N -e "SHOW VARIABLES LIKE 'version_ssl_library'" | grep OpenSSL > /dev/null
${prefix}/bin/mariadb-dump --no-defaults --socket=${socket} -uroot armtest | grep 'Grüße vom ARM' > /dev/null
${prefix}/bin/mariadb-admin --no-defaults --socket=${socket} -uroot shutdown
wait
grep 'Shutdown complete' ${data}/server.err > /dev/null
CHECK
    VERSION=${VERSION} bash /check/check.sh
    rm -rf ${prefix} /check ${OUTPUT_ROOT}/armhf-unchecked
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    download
    build_libsystemd
    rm -rf ${OUTPUT_PATH}
    assemble
    du -sh ${OUTPUT_PATH}

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
