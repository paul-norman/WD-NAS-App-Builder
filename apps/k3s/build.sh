#!/bin/bash
. '../build_helpers.sh'

# k3s and the kernel modules it needs are prepared by static/k3s (which the root build.sh runs first) - for the Intel
# models with modules built from WD's GPL source (the DL2100's archive is truncated, so it has none: k3s can't work there)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/k3s" ] || [ ! -f "${STATIC_PATH}/firmware" ] || ! ls "${STATIC_PATH}"/*/xt_comment.ko > /dev/null 2>&1; then
        abort "k3s or its kernel modules not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
    fi

    # k3s itself, and the kernel modules (one folder per model, plus the firmware they were built for)
    mkdir -p binaries modules
    cp "${STATIC_PATH}/k3s" binaries/
    cp -r "${STATIC_PATH}/firmware" "${STATIC_PATH}"/MyCloud* modules/

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries modules
done

# Cleanup
. '../build_helpers.sh'
