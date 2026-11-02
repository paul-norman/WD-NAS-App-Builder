#!/bin/bash
. '../build_helpers.sh'

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

RELEASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${APP_UPSTREAM_VERSION}"

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Node Exporter's name for the architecture
    NE_ARCH='amd64'

    if [ "$ARCH" = 'armhf' ]; then
        NE_ARCH='armv7'
    fi

    NE_NAME="node_exporter-${APP_UPSTREAM_VERSION}.linux-${NE_ARCH}"

    # Download, check against the release's published checksums and extract (Node Exporter is a single static binary)
    mkdir -p binaries
    cd binaries

    if ! download "${RELEASE_URL}/${NE_NAME}.tar.gz" "${NE_NAME}.tar.gz" || ! download "${RELEASE_URL}/sha256sums.txt" "node_exporter-${APP_UPSTREAM_VERSION}-sha256sums.txt"; then
        abort "Node Exporter ${APP_UPSTREAM_VERSION} could not be downloaded for: ${NE_ARCH}"
    fi

    if ! grep "  ${NE_NAME}.tar.gz$" "node_exporter-${APP_UPSTREAM_VERSION}-sha256sums.txt" | sha256sum -c -; then
        abort "${NE_NAME}.tar.gz failed its checksum check"
    fi

    tar -xzf "${NE_NAME}.tar.gz"
    mv "${NE_NAME}/node_exporter" node_exporter
    rm -rf "${NE_NAME}" "${NE_NAME}.tar.gz" "node_exporter-${APP_UPSTREAM_VERSION}-sha256sums.txt"
    cd ../

    # smartctl, for the disks' SMART attributes: built static by static/node_exporter (which the root build.sh runs
    # first) for the Intel models - the ARM models use the NAS's own smartctl, if it has one
    if [ "${ARCH}" = 'amd64' ]; then
        STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

        if [ ! -x "${STATIC_PATH}/smartctl" ]; then
            abort "smartctl not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
        fi
        cp "${STATIC_PATH}/smartctl" binaries/
    fi

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
