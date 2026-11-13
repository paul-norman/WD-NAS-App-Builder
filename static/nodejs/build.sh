#!/bin/bash

# Prepares Node.js for the NAS - for the Intel models its official build (checked against its SHA256), for the ARM ones
# built from its source (Node.js publishes no 32-bit ARM builds since version 24): node fully static (musl), with npm
# and Corepack, as Node's own release is laid out (bin, include, lib, share).

# The ARM build is cross-compiled on this (Intel) machine with Zig: node for the ARM models' ARMv7 processors
# (hard-float, NEON), laid out for their kernels' large memory pages - 32KB on the EX2 Ultra - and Node's build-time
# tools for 32-bit Intel (V8 makes its start-up snapshot with them, and they must match the ARM program's 32-bit memory
# layout). Checked for that layout (ci/check_arm_pages.py) and run with QEMU's emulator: crypto, Intl (all of ICU's
# data, built in), npm.

set -e
set -o pipefail
set -x

VERSION=26.13.1
# As Node.js's SHASUMS256.txt (signed by its releasers) publishes them: its Intel build, and its source
NODE_SHA256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
NODE_SOURCE_SHA256=a7f6204ff63b6a2cd274d48903285abb86ed53a99070e532d4c2fd787457d9e6
# The architectures built (each into packages/static/nodejs/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=/build/tools

# Writes the compilers' commands: Zig's for the ARM models (arm-cc, arm-c++, arm-ar, arm-ranlib) and for 32-bit Intel,
# for the build-time tools (host-cc, host-c++).
function make_tools() {
    local tool target

    mkdir -p ${TOOLS_PATH}
    # (a source read from its input - as Node's configure reads OpenSSL's settings and the processors' kinds - goes
    # through a file first: Zig hands input from stdin to bare clang, without its musl headers or its target names)
    for tool in arm-cc arm-c++ host-cc host-c++; do
        case "${tool}" in
            arm-*) target='arm-linux-musleabihf -mcpu=cortex_a9' ;;
            host-*) target='x86-linux-musl' ;;
        esac

        cat > ${TOOLS_PATH}/${tool} <<SH
#!/bin/sh
input=''

for arg in "\$@"; do
    shift

    # (Node's -march=armv7-a: Zig takes it for a processor's name - its own -mcpu already names an ARMv7-A one)
    case "\${arg}" in
        -march=*) continue ;;
    esac

    if [ "\${arg}" = - ]; then
        input="\$(mktemp /tmp/cc-input-XXXXXX).c"
        cat > "\${input}"
        arg="\${input}"
    fi

    set -- "\$@" "\${arg}"
done

zig ${tool#*-} -target ${target} "\$@"
status=\$?
[ -n "\${input}" ] && rm -f "\${input}" "\${input%.c}"

exit \${status}
SH
    done

    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/*
}

# Builds Node.js for the ARM models and installs it into ${BUILD_PATH}/install. Without Temporal (the new date and time
# API, which Node's Intel build has): Node builds its Rust part for the machine it's built on, not for the ARM models.
function build_node() {
    cd ${BUILD_PATH}
    tar -xf node.tar.xz
    cd node-v${VERSION}

    # Node's OpenSSL picks its settings for x32 (64-bit Intel with 32-bit pointers) wherever __ILP32__ is defined - as
    # gcc defines it only there, but Zig's clang does for every 32-bit processor, ARM too: x32 only on 64-bit Intel
    grep -l 'defined(__ILP32__)' deps/openssl/config/*.h > ${BUILD_PATH}/ilp32.txt
    [ -s ${BUILD_PATH}/ilp32.txt ]
    xargs sed -i 's/defined(__ILP32__)/defined(__ILP32__) \&\& defined(__x86_64__)/' < ${BUILD_PATH}/ilp32.txt

    CC=${TOOLS_PATH}/arm-cc CXX=${TOOLS_PATH}/arm-c++ AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib \
        CC_host=${TOOLS_PATH}/host-cc CXX_host=${TOOLS_PATH}/host-c++ AR_host='zig ar' RANLIB_host='zig ranlib' \
        ./configure --prefix=/ --dest-cpu=arm --dest-os=linux --cross-compiling --fully-static \
        --with-arm-float-abi=hard --with-arm-fpu=neon --with-intl=full-icu --v8-disable-temporal-support
    # (what it found: ARM for node, 32-bit Intel for its build-time tools, OpenSSL 3)
    grep -E '"(host_arch|target_arch|arm_fpu|openssl_version)"' config.gypi
    grep '"host_arch": "ia32"' config.gypi > /dev/null
    make -j "$(nproc)" CC=${TOOLS_PATH}/arm-cc CXX=${TOOLS_PATH}/arm-c++ CC.host=${TOOLS_PATH}/host-cc \
        CXX.host=${TOOLS_PATH}/host-c++
    make install DESTDIR=${BUILD_PATH}/install PREFIX=/
    arm-none-eabi-strip ${BUILD_PATH}/install/bin/node
}

# Checks the build: node fully static, laid out for large memory pages, and working under QEMU - its version, crypto,
# Intl with all of ICU's languages, and npm (run by it).
function check() {
    local node=${BUILD_PATH}/install/bin/node
    local run='qemu-arm -cpu cortex-a9'
    # (a month's name in German: from ICU's full data)
    local month="new Intl.DateTimeFormat('de-DE', { month: 'long', timeZone: 'UTC' })"

    if ! file ${node} | grep -E 'statically linked|static-pie linked' > /dev/null; then
        echo "node isn't static: $(file ${node})"

        exit 1
    fi

    python3 /data/ci/check_arm_pages.py ${node}
    [ "$(${run} ${node} --version)" = "v${VERSION}" ]
    [ "$(${run} ${node} -e "console.log(require('crypto').createHash('sha256').update('nas').digest('hex'))")" \
        = "$(printf 'nas' | sha256sum | cut -d ' ' -f 1)" ]
    [ "$(${run} ${node} -e "console.log(${month}.format(new Date(Date.UTC(2026, 2))))")" = 'März' ]
    ${run} ${node} ${BUILD_PATH}/install/lib/node_modules/npm/bin/npm-cli.js --version
}

# Puts Node.js's official Intel build (built for glibc: it can't run here) into ${BUILD_PATH}/amd64.
function prepare_intel() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://nodejs.org/dist/v${VERSION}/node-v${VERSION}-linux-x64.tar.xz" node-x64.tar.xz \
        "${NODE_SHA256}"
    tar -xf node-x64.tar.xz
    mv node-v${VERSION}-linux-x64 amd64
}

function run() {
    local root=/data/packages/static/nodejs/${VERSION}

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}
    cd ${BUILD_PATH}

    sh /data/static/fetch.sh "https://nodejs.org/dist/v${VERSION}/node-v${VERSION}.tar.xz" node.tar.xz \
        "${NODE_SOURCE_SHA256}"
    make_tools
    build_node
    check
    prepare_intel

    # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
    rm -rf ${root}/amd64 ${root}/armhf
    mkdir -p ${root}
    cp -a ${BUILD_PATH}/amd64 ${root}/amd64
    cp -a ${BUILD_PATH}/install ${root}/armhf
    du -sh ${root}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/nodejs/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
