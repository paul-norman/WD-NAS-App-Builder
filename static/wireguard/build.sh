#!/bin/sh

# Prepares WireGuard for the NAS - for the Intel models and the ARM ones - every program fully static, so nothing
# depends on the NAS's own libraries:
#  - wireguard-go: WireGuard's official userspace implementation (WD's kernels predate WireGuard in the kernel, 5.6). It
#                  needs only the kernel's TUN device, which WD ships as a module (as Tailscale uses it)
#  - wg:           WireGuard's own tool - keys, the interface's configuration, and the devices' status
#  - qrencode:     QR codes of the devices' configurations, for phones' WireGuard apps (SVG only: built without libpng)
#
# The ARM models' programs are built on this (Intel) machine: wireguard-go by Go's own cross-compiler (ARMv7), the C
# programs with Zig (ARMv7, hard-float, musl), and every one checked with QEMU's emulator.

set -e
set -x

VERSION=0.0.20250522
WG_GO_SHA256=c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c
WG_TOOLS_VERSION=1.0.20260223
WG_TOOLS_SHA256=af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf
QRENCODE_VERSION=4.1.1
QRENCODE_SHA256=5385bc1b8c2f20f3b91d258bf8ccc8cf62023935df2d2676b5b67049f31a049c
# The architectures built (each into packages/static/wireguard/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=/build/tools
OUTPUT_ROOT=/data/packages/static/wireguard/${VERSION}

# Downloads a file and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   The file to save it as (in the build folder)
# $3 sha256 Its SHA256
fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Writes the ARM compiler's commands (Zig's, for the ARM models' processors): arm-cc, arm-ar and arm-ranlib - commands
# of their own, as CMake takes a compiler without arguments.
make_tools() {
    mkdir -p ${TOOLS_PATH}
    printf '#!/bin/sh\nexec zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 "$@"\n' > ${TOOLS_PATH}/arm-cc
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/arm-cc ${TOOLS_PATH}/arm-ar ${TOOLS_PATH}/arm-ranlib
}

# Runs a program built for an architecture here (an ARM one with QEMU's emulator, as a Cortex-A9 - the ARM models'
# processors' kind).
#
# $1 arch The architecture (amd64 or armhf)
# $@      The program and its arguments
run_for() {
    arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 "$@"
    else
        "$@"
    fi
}

# Builds the three programs for an architecture, into ${BUILD_PATH}/<arch>/out.
#
# $1 arch The architecture (amd64 or armhf)
build() {
    arch="$1"
    dir=${BUILD_PATH}/${arch}
    mkdir -p ${dir}/out

    # wireguard-go (its Go modules are checked against its go.sum)
    cd ${dir}
    tar -xJf ${BUILD_PATH}/wireguard-go.tar.xz
    cd wireguard-go-${VERSION}

    if [ "${arch}" = armhf ]; then
        CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags '-s -w' -o ${dir}/out/wireguard-go
    else
        CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o ${dir}/out/wireguard-go
    fi

    # wg
    cd ${dir}
    tar -xJf ${BUILD_PATH}/wireguard-tools.tar.xz

    if [ "${arch}" = armhf ]; then
        make -C wireguard-tools-${WG_TOOLS_VERSION}/src -j "$(nproc)" wg CC=${TOOLS_PATH}/arm-cc LDFLAGS=-static
        arm-none-eabi-strip -o ${dir}/out/wg wireguard-tools-${WG_TOOLS_VERSION}/src/wg
    else
        make -C wireguard-tools-${WG_TOOLS_VERSION}/src -j "$(nproc)" wg LDFLAGS=-static
        strip -o ${dir}/out/wg wireguard-tools-${WG_TOOLS_VERSION}/src/wg
    fi

    # qrencode
    cd ${dir}
    tar -xzf ${BUILD_PATH}/qrencode.tar.gz
    cross=''

    if [ "${arch}" = armhf ]; then
        cross="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_C_COMPILER=${TOOLS_PATH}/arm-cc
            -DCMAKE_AR=${TOOLS_PATH}/arm-ar -DCMAKE_RANLIB=${TOOLS_PATH}/arm-ranlib"
    fi

    # shellcheck disable=SC2086
    cmake -S libqrencode-${QRENCODE_VERSION} -B qrencode-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DWITH_TOOLS=ON -DWITHOUT_PNG=ON -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ${cross}
    cmake --build qrencode-build -j "$(nproc)" --target qrenc

    if [ "${arch}" = armhf ]; then
        arm-none-eabi-strip -o ${dir}/out/qrencode qrencode-build/qrencode
    else
        strip -o ${dir}/out/qrencode qrencode-build/qrencode
    fi
}

# Checks an architecture's programs: fully static, and each runs - wg makes a key pair, qrencode a QR code.
#
# $1 arch The architecture (amd64 or armhf)
check() {
    arch="$1"
    out=${BUILD_PATH}/${arch}/out

    for program in wireguard-go wg qrencode; do
        if ! file ${out}/${program} | grep -E 'statically linked|static-pie linked' > /dev/null; then
            echo "${program} (${arch}) isn't static: $(file ${out}/${program})"

            exit 1
        fi
    done

    run_for ${arch} ${out}/wireguard-go --version | grep "wireguard-go v${VERSION}" > /dev/null
    run_for ${arch} ${out}/wg --version | grep "wireguard-tools v${WG_TOOLS_VERSION}" > /dev/null
    key="$(run_for ${arch} ${out}/wg genkey)"
    public="$(echo "${key}" | run_for ${arch} ${out}/wg pubkey)"

    if [ ${#key} != 44 ] || [ ${#public} != 44 ] || [ "${key}" = "${public}" ]; then
        echo "wg (${arch}) didn't make a key pair: ${key} / ${public}"

        exit 1
    fi

    echo test | run_for ${arch} ${out}/qrencode -t SVG -o - | grep '<svg' > /dev/null
}

rm -rf ${BUILD_PATH}
mkdir -p ${BUILD_PATH}
fetch "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-${VERSION}.tar.xz" wireguard-go.tar.xz ${WG_GO_SHA256}
fetch "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${WG_TOOLS_VERSION}.tar.xz" wireguard-tools.tar.xz \
    ${WG_TOOLS_SHA256}
fetch "https://github.com/fukuchi/libqrencode/archive/refs/tags/v${QRENCODE_VERSION}.tar.gz" qrencode.tar.gz \
    ${QRENCODE_SHA256}
make_tools

for arch in ${ARCHES}; do
    build ${arch}
    check ${arch}
    # Only once it's checked (build_static.sh takes an output folder that isn't empty as built)
    rm -rf ${OUTPUT_ROOT}/${arch}
    mkdir -p ${OUTPUT_ROOT}/${arch}
    cp ${BUILD_PATH}/${arch}/out/* ${OUTPUT_ROOT}/${arch}/
    ls -la ${OUTPUT_ROOT}/${arch}
done

# Create a latest release file for ease of use in packages
LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
echo "Creating a latest release file: ${LATEST_PATH}"
rm -f ${LATEST_PATH}
printf '%s' "${VERSION}" > ${LATEST_PATH}

chown -R "${HOST_IDS:-1000:1000}" /data/packages
