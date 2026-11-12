#!/bin/bash

# MariaDB for the NAS: MariaDB's own Linux release (built for glibc 2.28+, the NAS has 2.31), checked against its
# published checksum, cut down to what a server needs (no test suite, Galera, or plugins needing libraries the NAS
# doesn't have) and stripped. Its server needs libsystemd only to tell systemd it's ready - which the NAS doesn't run -
# so a stand-in library is added, found through a fixed path (/usr/local/mysql/lib: the app links /usr/local/mysql to
# these files, which is also where MariaDB's release looks for its plugins, messages and character sets).
#
# The ARM models: MariaDB publishes no 32-bit ARM release, so armhf.sh compiles the same version from its source with
# Debian's cross-compiler - inside the Dockerfile's Debian stage (/armhf-root, with chroot) - and bundles the libraries
# it uses with it. It's checked here with QEMU's emulator: a new database, the server, InnoDB, the client tools.

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
# The ARM build environment (the Dockerfile's Debian stage), and where the ARM build is made inside it: the path the app
# links to MariaDB on the NAS, as its programs find their libraries by their full paths
ARM_ROOT=/armhf-root
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

# The stand-in for libsystemd: the three functions MariaDB's server calls, doing nothing (as with no systemd)
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
    gcc -O2 -fPIC -shared -o libsystemd.so.0 -Wl,-soname,libsystemd.so.0 -Wl,--version-script=libsystemd.map libsystemd.c
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

# Builds MariaDB for the ARM models with armhf.sh, in the Debian stage (with chroot: its own /dev entries made first, as
# the build needs them), into ${BUILD_PATH}/armhf-out (until it's checked) - and its bundled libraries' sources.
function build_arm() {
    local work=${ARM_ROOT}/work
    local device

    rm -rf ${work}
    mkdir -p ${work}
    cd ${work}
    sh /data/static/fetch.sh "https://archive.mariadb.org/mariadb-${VERSION}/source/mariadb-${VERSION}.tar.gz" \
        mariadb.tar.gz "${SOURCE_SHA256}"
    cp /data/static/mariadb/armhf.sh ${work}/

    for device in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9'; do
        set -- ${device}
        [ -e ${ARM_ROOT}/dev/$1 ] || mknod -m 666 ${ARM_ROOT}/dev/$1 c $2 $3
    done

    cp /etc/resolv.conf ${ARM_ROOT}/etc/resolv.conf
    chroot ${ARM_ROOT} /usr/bin/env VERSION=${VERSION} /bin/bash /work/armhf.sh

    rm -rf ${BUILD_PATH}/armhf-out
    mkdir -p ${BUILD_PATH}/armhf-out
    cp -a ${ARM_ROOT}${ARM_PREFIX}/. ${BUILD_PATH}/armhf-out/
    mkdir -p ${OUTPUT_PATH}.sources
    rm -rf ${OUTPUT_PATH}.sources/armhf-debian
    cp -r ${work}/sources ${OUTPUT_PATH}.sources/armhf-debian
    cd ${BUILD_PATH}
    rm -rf ${work}
    du -sh ${BUILD_PATH}/armhf-out ${OUTPUT_PATH}.sources/armhf-debian
}

# Checks the ARM build with QEMU's emulator (as a Cortex-A9, the ARM models' processors' kind), at the path the app links
# to it (where it finds its loader and libraries), without the Debian stage's libraries anywhere it could find them:
# each program runs, mariadb-install-db makes a new database, the server starts on it, stores and reads back data with
# InnoDB, mariadb-dump dumps it, and it shuts down cleanly. Its programs are run through scripts calling QEMU, so that
# MariaDB's own scripts can run them as on the NAS.
function check_arm() {
    local qemu='qemu-arm -cpu cortex-a9'
    local data=${BUILD_PATH}/armhf-test
    local socket=${BUILD_PATH}/armhf-test.sock
    local client program waited

    rm -rf ${ARM_PREFIX} ${data}
    cp -a ${BUILD_PATH}/armhf-out ${ARM_PREFIX}
    mv ${ARM_PREFIX}/bin ${ARM_PREFIX}/bin-arm
    mkdir ${ARM_PREFIX}/bin

    for program in ${ARM_PREFIX}/bin-arm/*; do
        printf '#!/bin/sh\nexec %s %s "$@"\n' "${qemu}" "${program}" > ${ARM_PREFIX}/bin/$(basename ${program})
        chmod 755 ${ARM_PREFIX}/bin/$(basename ${program})
    done

    ${ARM_PREFIX}/bin/mariadbd --version | tee ${BUILD_PATH}/armhf-version.txt
    grep "Ver ${VERSION}-MariaDB" ${BUILD_PATH}/armhf-version.txt > /dev/null
    ${ARM_PREFIX}/bin/mariadb-backup --version
    ${ARM_PREFIX}/scripts/mariadb-install-db --no-defaults --basedir=${ARM_PREFIX} --datadir=${data} --user=root \
        --auth-root-authentication-method=normal --skip-test-db

    ${ARM_PREFIX}/bin/mariadbd --no-defaults --basedir=${ARM_PREFIX} --datadir=${data} --user=root \
        --socket=${socket} --skip-networking --lc-messages-dir=${ARM_PREFIX}/share \
        --character-sets-dir=${ARM_PREFIX}/share/charsets --log-error=${data}/server.err &
    client="${ARM_PREFIX}/bin/mariadb --no-defaults --socket=${socket} -uroot"
    waited=0

    until ${client} -e 'SELECT 1' > /dev/null 2>&1; do
        if [ ${waited} -ge 120 ]; then
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
    ${ARM_PREFIX}/bin/mariadb-dump --no-defaults --socket=${socket} -uroot armtest | grep 'Grüße vom ARM' > /dev/null
    ${ARM_PREFIX}/bin/mariadb-admin --no-defaults --socket=${socket} -uroot shutdown
    wait
    grep 'Shutdown complete' ${data}/server.err > /dev/null
    rm -rf ${ARM_PREFIX} ${data}
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
