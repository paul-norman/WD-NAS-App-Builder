#!/bin/bash
. '../build_helpers.sh'

# Nginx is built as a static binary by static/nginx (which the root build.sh runs first); lego is downloaded from its
# official releases (also a static binary) - for the Intel models and the ARM ones (static/nginx's amd64 build makes
# both; lego's ARMv7 build for the ARM models)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

LEGO_VERSION=5.6.0

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Nginx and its standard parameter files, built for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/nginx" ] || [ ! -f "${STATIC_PATH}/params/mime.types" ]; then
        abort "Nginx not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} amd64)"
    fi

    mkdir -p binaries params
    cp "${STATIC_PATH}/nginx" binaries/
    cp "${STATIC_PATH}"/params/* params/

    # lego, checked against the checksums published with its release
    LEGO_ARCH="${ARCH/armhf/armv7}"
    LEGO_FILE="lego_v${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz"
    LEGO_URL="https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}"

    if ! download "${LEGO_URL}/${LEGO_FILE}" "${LEGO_FILE}" || ! download "${LEGO_URL}/lego_${LEGO_VERSION}_checksums.txt"; then
        abort "lego could not be downloaded from: ${LEGO_URL}"
    fi

    if ! grep " ${LEGO_FILE}$" "lego_${LEGO_VERSION}_checksums.txt" | sha256sum -c - > /dev/null; then
        abort "lego's download doesn't match its published checksum: ${LEGO_FILE}"
    fi

    tar -xzf "${LEGO_FILE}" -C binaries lego
    rm -f "${LEGO_FILE}" "lego_${LEGO_VERSION}_checksums.txt"

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries params
done

# Cleanup
. '../build_helpers.sh'
