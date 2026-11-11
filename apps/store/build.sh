#!/bin/bash
. '../build_helpers.sh'

# The Store's signature checker (store_verify, with Monocypher) is prepared by static/store (which the root build.sh runs
# first) - for the Intel models and the ARM ones (its amd64 build makes both)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'
STATIC_VERSION="$(cat "${REPO_PATH}/packages/static/${APP_NAME}/latest" 2>/dev/null)"

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${STATIC_VERSION}/${ARCH}"

    if [ -z "${STATIC_VERSION}" ] || [ ! -e "${STATIC_PATH}/store_verify" ]; then
        abort "store_verify not found in: ${STATIC_PATH} (run: ./build_static.sh ${APP_NAME} amd64)"
    fi

    mkdir -p binaries
    cp -r "${STATIC_PATH}"/* binaries/

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
