#!/bin/bash
. '../build_helpers.sh'

# PHP is built as static binaries by static/php (which the root build.sh runs first) - for the Intel models only
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # PHP's CLI and FPM, built for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/php" ] || [ ! -x "${STATIC_PATH}/php-fpm" ]; then
        abort "PHP not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
    fi

    mkdir -p binaries
    cp "${STATIC_PATH}/php" "${STATIC_PATH}/php-fpm" binaries/

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
