#!/bin/bash
. '../build_helpers.sh'

# PHP is built by static/php (which the root build.sh runs first) - for the Intel models (static binaries) and the
# ARM ones (with the libraries and glibc they use, in runtime/: its amd64 build makes both)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # PHP's CLI and FPM, built for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/php" ] || [ ! -x "${STATIC_PATH}/php-fpm" ]; then
        abort "PHP not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} amd64)"
    fi

    mkdir -p binaries
    cp "${STATIC_PATH}/php" "${STATIC_PATH}/php-fpm" binaries/

    if [ "${ARCH}" = armhf ]; then
        if [ ! -x "${STATIC_PATH}/runtime/ld-linux-armhf.so.3" ]; then
            abort "PHP's libraries not found in: ${STATIC_PATH}/runtime (run: ./build_static.sh ${APP_NAME} amd64)"
        fi

        cp -a "${STATIC_PATH}/runtime" binaries/
    fi

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
