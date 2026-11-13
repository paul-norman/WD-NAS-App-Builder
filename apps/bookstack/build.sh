#!/bin/bash
. '../build_helpers.sh'

# BookStack with its PHP packages, and its run-as helper (bookstack_runas), are prepared by static/bookstack (which the
# root build.sh runs first) - for the Intel models and the ARM ones (its amd64 build makes both). It runs on the PHP
# app's PHP
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    for file in bookstack_runas bookstack/artisan bookstack/vendor/autoload.php; do
        if [ ! -e "${STATIC_PATH}/${file}" ]; then
            how="set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh"
            abort "${file} not found in: ${STATIC_PATH} (${how} and run: ./build_static.sh ${APP_NAME} amd64)"
        fi
    done

    mkdir -p binaries
    cp -r "${STATIC_PATH}"/* binaries/
    # Its folders for data: the app keeps BookStack's own in Nas_Prog/_bookstack (linked back in its place), begun from
    # these
    mv binaries/bookstack/storage binaries/bookstack/storage.dist

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
