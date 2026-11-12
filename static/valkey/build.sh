#!/bin/bash

# Builds ValKey's server and client fully static (musl) - for the Intel models with gcc (ValKey picks its fastest code
# for the processor it runs on - e.g. AVX2 - with gcc's runtime), for the ARM ones with Zig (its own musl; for their
# ARMv7 processors, hard-float, laid out for their kernels' large memory pages - 32KB on the EX2 Ultra). The ARM build uses musl's memory allocator: jemalloc is built for one page size, and the ARM models' differ.
#
# ValKey 9 finds its built-in Lua scripting engine's two entry points in its own program with dlopen(NULL) and dlsym(),
# which a static program can't do: patched to return them directly. Each build is checked: a server started, the client
# setting and getting a key and running a Lua script (the ARM one with QEMU's emulator, after its layout check:
# ci/check_arm_pages.py).

set -e
set -o pipefail
set -x

VERSION=9.1.3
# Checked against Valkey's own published hash (github.com/valkey-io/valkey-hashes)
VALKEY_SHA256=184e34ed2d9b51879b682b5b15205e2b9d677c60280e3cb453be8f520d04e293
# The architectures built (each into packages/static/valkey/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=/build/tools
OUTPUT_ROOT=/data/packages/static/valkey/${VERSION}

# Writes each architecture's compiler commands: <arch>-cc, <arch>-c++, <arch>-ar and <arch>-ranlib (gcc's for amd64,
# Zig's for armhf).
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    ln -sf /usr/bin/gcc ${TOOLS_PATH}/amd64-cc
    ln -sf /usr/bin/g++ ${TOOLS_PATH}/amd64-c++
    ln -sf /usr/bin/gcc-ar ${TOOLS_PATH}/amd64-ar
    ln -sf /usr/bin/gcc-ranlib ${TOOLS_PATH}/amd64-ranlib
    printf '#!/bin/sh\nexec zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 "$@"\n' > ${TOOLS_PATH}/armhf-cc
    printf '#!/bin/sh\nexec zig c++ -target arm-linux-musleabihf -mcpu=cortex_a9 "$@"\n' > ${TOOLS_PATH}/armhf-c++
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/armhf-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/armhf-ranlib
    chmod 755 ${TOOLS_PATH}/armhf-*
}

# Lets a static ValKey find its built-in Lua engine: its two entry points returned directly, rather than looked up in
# its own program with dlopen(NULL) and dlsym() - stopping if ValKey's code isn't as expected.
#
# $1 source ValKey's source folder
function patch_static_lua() {
    local module="$1/src/module.c"
    local marker='    /* Open a handle to self */'

    grep -F 'static int moduleLoadStaticSymbol(void **out, void **handle, const char *symbol_name, const char *module_name) {' \
        ${module} > /dev/null
    [ "$(grep -cF "${marker}" ${module})" = 1 ]
    awk -v marker="${marker}" '
        /^static int moduleLoadStaticSymbol\(void \*\*out, void \*\*handle,/ {
            print "/* The built-in Lua engine'"'"'s entry points, for a static build (no dlopen) */"
            print "int ValkeyModule_OnLoad_lua(void *ctx, void **argv, int argc);"
            print "int ValkeyModule_OnUnload_lua(void *ctx);"
            print ""
        }
        $0 == marker {
            print "    /* A static program can'"'"'t dlopen() itself: the built-in Lua engine'"'"'s entry points, directly */"
            print "    if (strcmp(symbol_full_name, \"ValkeyModule_OnLoad_lua\") == 0) {"
            print "        *out = (void *)(unsigned long)ValkeyModule_OnLoad_lua;"
            print "        *handle = NULL;"
            print "        return C_OK;"
            print "    }"
            print "    if (strcmp(symbol_full_name, \"ValkeyModule_OnUnload_lua\") == 0) {"
            print "        *out = (void *)(unsigned long)ValkeyModule_OnUnload_lua;"
            print "        *handle = NULL;"
            print "        return C_OK;"
            print "    }"
            print ""
        }
        { print }
    ' ${module} > ${module}.new
    mv ${module}.new ${module}
    grep -F 'return C_OK;' ${module} > /dev/null
}

# Builds ValKey for an architecture (fully static) into ${BUILD_PATH}/<arch>/out.
#
# $1 arch The architecture (amd64 or armhf)
function build_valkey() {
    local arch="$1"
    local source=${BUILD_PATH}/${arch}/valkey
    local malloc=jemalloc

    # (musl's allocator for the ARM models: jemalloc is built for one memory page size)
    [ "${arch}" = armhf ] && malloc=libc

    mkdir -p ${source} ${BUILD_PATH}/${arch}/out
    tar -xzf ${BUILD_PATH}/valkey.tar.gz -C ${source} --strip-components=1
    patch_static_lua ${source}
    make -C ${source} -j "$(nproc)" CC=${TOOLS_PATH}/${arch}-cc CXX=${TOOLS_PATH}/${arch}-c++ \
        AR=${TOOLS_PATH}/${arch}-ar RANLIB=${TOOLS_PATH}/${arch}-ranlib MALLOC=${malloc} USE_SYSTEMD=no BUILD_TLS=no \
        LDFLAGS=-static

    if [ "${arch}" = armhf ]; then
        arm-none-eabi-strip -o ${BUILD_PATH}/${arch}/out/valkey-server ${source}/src/valkey-server
        arm-none-eabi-strip -o ${BUILD_PATH}/${arch}/out/valkey-cli ${source}/src/valkey-cli
    else
        strip -o ${BUILD_PATH}/${arch}/out/valkey-server ${source}/src/valkey-server
        strip -o ${BUILD_PATH}/${arch}/out/valkey-cli ${source}/src/valkey-cli
    fi
}

# Checks a build: fully static (the ARM one laid out for large memory pages), and working - a server started, the client
# setting and getting a key and running a Lua script (the ARM one with QEMU).
#
# $1 arch The architecture (amd64 or armhf)
function check() {
    local arch="$1"
    local out=${BUILD_PATH}/${arch}/out
    local run='' cli pid i program

    for program in valkey-server valkey-cli; do
        if ! file ${out}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${out}/${program})"

            exit 1
        fi
    done

    if [ "${arch}" = armhf ]; then
        python3 /data/ci/check_arm_pages.py ${out}
        run='qemu-arm -cpu cortex-a9'
    fi

    ${run} ${out}/valkey-server --version | grep "v=${VERSION}" > /dev/null
    rm -rf /tmp/valkey-test
    mkdir -p /tmp/valkey-test
    ${run} ${out}/valkey-server --port 16379 --bind 127.0.0.1 --dir /tmp/valkey-test --save '' \
        > /tmp/valkey-test/server.log 2>&1 &
    pid=$!
    cli="${run} ${out}/valkey-cli -p 16379"

    for i in $(seq 1 60); do
        [ "$(${cli} PING 2>/dev/null)" = PONG ] && break
        sleep 1
    done

    [ "$(${cli} PING)" = PONG ]
    ${cli} SET arm 'Grüße vom ARM' > /dev/null
    [ "$(${cli} GET arm)" = 'Grüße vom ARM' ]
    [ "$(${cli} EVAL "return redis.call('GET', KEYS[1]) .. ' (Lua)'" 1 arm)" = 'Grüße vom ARM (Lua)' ]
    ${cli} SHUTDOWN NOSAVE > /dev/null 2>&1 || true
    wait ${pid} 2> /dev/null || true
}

function run() {
    local arch

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    sh /data/static/fetch.sh "https://github.com/valkey-io/valkey/archive/refs/tags/${VERSION}.tar.gz" \
        valkey.tar.gz "${VALKEY_SHA256}"
    make_tools

    for arch in ${ARCHES}; do
        build_valkey ${arch}
        check ${arch}

        # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
        rm -rf ${OUTPUT_ROOT}/${arch}
        mkdir -p ${OUTPUT_ROOT}/${arch}
        cp ${BUILD_PATH}/${arch}/out/* ${OUTPUT_ROOT}/${arch}/
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
