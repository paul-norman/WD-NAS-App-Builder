#!/bin/bash

# Prepares MongoDB for the NAS: its server (mongod) built from source for processors WITHOUT AVX - MongoDB's own
# builds (5.0 and later) need AVX, which the NAS's Pentium / Celeron / Atom processors don't have, so they stop at
# once there ("Illegal instruction"). Built as MongoDB builds its releases (Bazel, its own compilers), with three
# changes - as FreeBSD's, Gentoo's and others' no-AVX builds do:
#  - its x86-64 builds target Sandy Bridge (AVX): here x86-64-v2 (SSE4.2, SSSE3, POPCNT - what the NAS has)
#  - its JavaScript engine (mozjs, for $where, $function and map-reduce) is compiled with AVX2: here without, and its
#    AVX2 helpers left out (its SSE2 ones are used)
#  - no HTTP client (it's only for MongoDB's cloud services), so no libcurl
# Then checked: no newer glibc than the NAS's, and run on an emulated CPU without AVX (QEMU, as a Nehalem - SSE4.2,
# no AVX, no AES), storing and querying documents, JavaScript included. Alongside it:
#  - OpenSSL 3.5 (shared, built from source - for TLS), bundled with it
#  - mongosh (MongoDB's shell, its official build) and MongoDB's database tools (mongodump, mongorestore...)
#  - mongodb_runas: switches to MongoDB's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=8.0.34
# GitHub's archive of its release tag
MONGO_SHA256=b86778267f530e430fc3013a37578e9698cf9b58aa185e93f0cf5c8e92465974
# Bazelisk (which runs the Bazel version MongoDB names): GitHub's release - identical to MongoDB's own copy
BAZELISK_VERSION=1.26.0
BAZELISK_SHA256=6539c12842ad76966f3d493e8f80d67caa84ec4a000e220d5459833c967c12bc
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
# mongosh's linux-x64 build (with its own OpenSSL), as GitHub publishes its digest
MONGOSH_VERSION=2.14.1
MONGOSH_SHA256=8d24940ebe3675959b518fd41ea16b4e2182d6a75c09777db09cfa64e18834a1
# MongoDB's database tools, their Debian 11 build (MongoDB publishes no checksums for them)
TOOLS_VERSION=100.20.1
TOOLS_SHA256=7c0d5db529dab4ac3dd80c5c30399c6a55802eb5697be4016944fd4aee46d408
# The newest glibc symbol version the NAS has (OS5: glibc 2.31)
NAS_GLIBC=2.31

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/mongodb/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Whether version $1 is newer than version $2
function newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Every program and library must run with the NAS's own glibc
function check_glibc() {
    local file glibc

    for file in "$@"; do
        glibc="$(objdump -T "${file}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -V | tail -n 1)"
        echo "${file}: GLIBC ${glibc:-none}"

        if [ -n "${glibc}" ] && newer "${glibc}" "${NAS_GLIBC}"; then
            echo "${file} needs a newer glibc than the NAS has"

            exit 1
        fi
    done
}

# Replaces text in a file, stopping the build if it isn't there (e.g. MongoDB changed it)
function replace() {
    grep -qF -- "$2" "$1" || { echo "Not found in $1: $2"; exit 1; }
    FROM="$2" TO="$3" perl -0 -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"
}

function build_openssl() {
    fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl.tar.gz ${OPENSSL_SHA256}
    tar -xzf openssl.tar.gz
    cd openssl-${OPENSSL_VERSION}
    # Into the system's own folders, where MongoDB's compilers look (Bazel refuses folders of its own outside the
    # source tree); OpenSSL picks its processor-specific code when it runs
    ./Configure --prefix=/usr --libdir=lib/x86_64-linux-gnu --openssldir=/usr/lib/ssl shared no-tests no-docs
    make -j "$(nproc)"
    make install_sw
}

function build_mongod() {
    fetch "https://github.com/mongodb/mongo/archive/refs/tags/r${VERSION}.tar.gz" mongo.tar.gz ${MONGO_SHA256}
    fetch "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-amd64" \
        bazelisk ${BAZELISK_SHA256}
    chmod +x bazelisk
    tar -xzf mongo.tar.gz
    cd mongo-r${VERSION}
    # Every Bazel run builds here, without MongoDB's own build cluster (also its wrapper's own runs, e.g. the one that
    # installs its Python)
    echo 'common --config=local' > .bazelrc.local

    # Its Enterprise modules (not public) are listed in its headers' library: left out, as Gentoo's build does
    grep -q 'enterprise' src/BUILD.bazel
    sed -i '/enterprise/d' src/BUILD.bazel

    # Its x86-64 target: x86-64-v2 rather than Sandy Bridge
    replace bazel/toolchains/cc/mongo_linux/mongo_compiler_flags.bzl '"-march=sandybridge",' '"-march=x86-64-v2",'
    # Its JavaScript engine without AVX2: not compiled with it, and its AVX2 helpers only where AVX2 is the target
    replace src/third_party/mozjs/BUILD.bazel ' + (["-mavx2"] if arch == "x86_64" and os != "windows" else [])' ''
    replace src/third_party/mozjs/BUILD.bazel '"//bazel/config:linux_x86_64": ["-mavx2"],' \
        '"//bazel/config:linux_x86_64": [],'
    replace src/third_party/mozjs/extract/mozglue/misc/SIMD.cpp \
        '#  if defined(MOZILLA_MAY_SUPPORT_AVX2) && defined(__x86_64__)' \
        '#  if defined(MOZILLA_MAY_SUPPORT_AVX2) && defined(__x86_64__) && defined(__AVX2__)'
    replace src/third_party/mozjs/extract/mozglue/misc/SIMD_avx2.cpp \
        '#if defined(MOZILLA_MAY_SUPPORT_AVX2) && defined(__x86_64__)' \
        '#if defined(MOZILLA_MAY_SUPPORT_AVX2) && defined(__x86_64__) && defined(__AVX2__)'

    # MongoDB's release settings (optimised, statically linked), without its Enterprise modules, debug symbols or HTTP
    # client; TLS with the OpenSSL built above (bundled: found next to mongod, in ../lib)
    ${BUILD_PATH}/bazelisk build --config=local -c opt --//bazel/config:opt=on --linkstatic=True \
        --build_enterprise=False --http_client=False --ssl=True --//bazel/config:debug_symbols=False \
        --separate_debug=False --fission=no --disable_warnings_as_errors=True --strip=always \
        --define=MONGO_VERSION=${VERSION} \
        --linkopt='-Wl,-rpath,$ORIGIN/../lib' \
        install-mongod
}

function build_tools() {
    cd ${BUILD_PATH}
    fetch "https://github.com/mongodb-js/mongosh/releases/download/v${MONGOSH_VERSION}/mongosh-${MONGOSH_VERSION}-linux-x64.tgz" \
        mongosh.tgz ${MONGOSH_SHA256}
    fetch "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian11-x86_64-${TOOLS_VERSION}.tgz" \
        tools.tgz ${TOOLS_SHA256}
    tar -xzf mongosh.tgz
    tar -xzf tools.tgz
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > mongodb_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: mongodb_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("mongodb_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("mongodb_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -o mongodb_runas mongodb_runas.c
    strip mongodb_runas
}

# Runs the built programs on an emulated CPU without AVX (or AES): starts mongod, stores and reads documents with
# mongosh (a query in JavaScript too, through its JavaScript engine), dumps them with mongodump, stops it
function check_without_avx() {
    local bin="${OUTPUT_PATH}/bin" db=/tmp/no-avx-db
    local emulate="qemu-x86_64 -cpu Nehalem"

    rm -rf ${db} && mkdir -p ${db}
    ${emulate} "${bin}/mongod" --version
    ${emulate} "${bin}/mongod" --dbpath ${db} --port 27999 --bind_ip 127.0.0.1 --logpath ${db}/mongod.log &
    local pid=$! waited=0

    until ${emulate} "${bin}/mongosh" --quiet --port 27999 --eval 'db.runCommand({ ping: 1 }).ok' 2>/dev/null \
        | grep -q 1; do
        if [ ${waited} -ge 180 ] || ! kill -0 ${pid} 2>/dev/null; then
            tail -n 20 ${db}/mongod.log

            exit 1
        fi

        sleep 3
        waited=$((waited + 3))
    done

    local result
    result="$(${emulate} "${bin}/mongosh" --quiet --port 27999 --eval '
        db.check.insertMany([{ n: 1, name: "one" }, { n: 2, name: "two" }, { n: 3, name: "three" }]);
        db.check.createIndex({ name: 1 });
        const found = db.check.find({ n: { $gte: 2 } }).count();
        const js = db.check.find({ $where: "this.n % 2 == 1" }).count();
        print("found=" + found + " js=" + js);')"
    echo "${result}"
    echo "${result}" | grep -q 'found=2 js=2'
    ${emulate} "${bin}/mongodump" --port 27999 --db test --out ${db}/dump
    [ -s ${db}/dump/test/check.bson ]
    kill ${pid}
    wait ${pid} || true
    echo 'mongod, mongosh and mongodump worked on a CPU without AVX'
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    mkdir -p ${BUILD_PATH}

    build_openssl
    build_mongod
    build_tools
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}/bin ${OUTPUT_PATH}/lib
    cp -L ${BUILD_PATH}/mongo-r${VERSION}/bazel-bin/install-mongod/bin/mongod ${OUTPUT_PATH}/bin/
    cp ${BUILD_PATH}/mongosh-${MONGOSH_VERSION}-linux-x64/bin/mongosh ${OUTPUT_PATH}/bin/
    for tool in mongodump mongorestore mongoexport mongoimport bsondump; do
        cp ${BUILD_PATH}/mongodb-database-tools-debian11-x86_64-${TOOLS_VERSION}/bin/${tool} ${OUTPUT_PATH}/bin/
    done

    cp ${BUILD_PATH}/mongodb_runas ${OUTPUT_PATH}/bin/
    cp -P /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3 ${OUTPUT_PATH}/lib/
    # Licences: MongoDB's (SSPL), mongosh's and the tools' (Apache-2.0), OpenSSL's
    cp ${BUILD_PATH}/mongo-r${VERSION}/LICENSE-Community.txt ${OUTPUT_PATH}/LICENSE-mongodb.txt
    cp ${BUILD_PATH}/mongosh-${MONGOSH_VERSION}-linux-x64/LICENSE-mongosh ${OUTPUT_PATH}/LICENSE-mongosh.txt
    cp ${BUILD_PATH}/mongodb-database-tools-debian11-x86_64-${TOOLS_VERSION}/LICENSE.md ${OUTPUT_PATH}/LICENSE-tools.md
    cp ${BUILD_PATH}/openssl-${OPENSSL_VERSION}/LICENSE.txt ${OUTPUT_PATH}/LICENSE-openssl.txt

    # Only the NAS's own glibc, and nothing else but what's bundled
    check_glibc ${OUTPUT_PATH}/bin/mongod ${OUTPUT_PATH}/bin/mongosh ${OUTPUT_PATH}/bin/mongodump \
        ${OUTPUT_PATH}/lib/libssl.so.3 ${OUTPUT_PATH}/lib/libcrypto.so.3
    ldd ${OUTPUT_PATH}/bin/mongod
    if ldd ${OUTPUT_PATH}/bin/mongod \
        | grep -v -E 'linux-vdso|ld-linux|lib(c|m|pthread|dl|rt|resolv|gcc_s)\.so|/lib/libssl\.so|/lib/libcrypto\.so' \
        | grep -q '=>'; then
        echo 'mongod needs libraries the NAS may not have'

        exit 1
    fi

    check_without_avx
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/bin/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
