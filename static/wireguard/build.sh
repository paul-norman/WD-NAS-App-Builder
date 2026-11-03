#!/bin/sh

# Prepares WireGuard for the NAS - every program fully static, so nothing depends on the NAS's own libraries:
#  - wireguard-go: WireGuard's official userspace implementation (WD's 4.14 kernel predates WireGuard in the kernel,
#                  5.6). It needs only the kernel's TUN device, which WD ships as a module (as Tailscale uses it)
#  - wg:           WireGuard's own tool - keys, the interface's configuration, and the devices' status
#  - qrencode:     QR codes of the devices' configurations, for phones' WireGuard apps (SVG only: built without libpng)

set -e
set -x

VERSION=0.0.20250522
WG_GO_SHA256=c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c
WG_TOOLS_VERSION=1.0.20260223
WG_TOOLS_SHA256=af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf
QRENCODE_VERSION=4.1.1
QRENCODE_SHA256=5385bc1b8c2f20f3b91d258bf8ccc8cf62023935df2d2676b5b67049f31a049c

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/wireguard/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

rm -rf ${BUILD_PATH}
mkdir -p ${BUILD_PATH}

# wireguard-go (its Go modules are checked against its go.sum)
fetch "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-${VERSION}.tar.xz" wireguard-go.tar.xz ${WG_GO_SHA256}
tar -xJf wireguard-go.tar.xz
cd wireguard-go-${VERSION}
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o ${BUILD_PATH}/wireguard-go

# wg
fetch "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${WG_TOOLS_VERSION}.tar.xz" wireguard-tools.tar.xz ${WG_TOOLS_SHA256}
tar -xJf wireguard-tools.tar.xz
make -C wireguard-tools-${WG_TOOLS_VERSION}/src -j "$(nproc)" wg LDFLAGS=-static
strip wireguard-tools-${WG_TOOLS_VERSION}/src/wg
cp wireguard-tools-${WG_TOOLS_VERSION}/src/wg ${BUILD_PATH}/wg

# qrencode
fetch "https://github.com/fukuchi/libqrencode/archive/refs/tags/v${QRENCODE_VERSION}.tar.gz" qrencode.tar.gz ${QRENCODE_SHA256}
tar -xzf qrencode.tar.gz
cmake -S libqrencode-${QRENCODE_VERSION} -B qrencode-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWITH_TOOLS=ON \
    -DWITHOUT_PNG=ON -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build qrencode-build -j "$(nproc)" --target qrenc
strip qrencode-build/qrencode
cp qrencode-build/qrencode ${BUILD_PATH}/qrencode

rm -rf ${OUTPUT_PATH}
mkdir -p ${OUTPUT_PATH}
cp ${BUILD_PATH}/wireguard-go ${BUILD_PATH}/wg ${BUILD_PATH}/qrencode ${OUTPUT_PATH}/

for program in wireguard-go wg qrencode; do
    if file ${OUTPUT_PATH}/${program} 2>/dev/null | grep -q dynamic; then
        echo "${program} isn't static"

        exit 1
    fi
done

${OUTPUT_PATH}/wireguard-go --version
${OUTPUT_PATH}/wg --version
echo test | ${OUTPUT_PATH}/qrencode -t SVG -o - | head -c 60; echo
ls -la ${OUTPUT_PATH}

# Create a latest release file for ease of use in packages
LATEST_PATH="$(dirname ${OUTPUT_PATH})"
LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
echo "Creating a latest release file: ${LATEST_PATH}"
rm -f ${LATEST_PATH}
printf '%s' "${VERSION}" > ${LATEST_PATH}

chown -R "${HOST_IDS:-1000:1000}" /data/packages
