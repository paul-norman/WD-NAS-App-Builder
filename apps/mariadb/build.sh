#!/bin/bash
. '../build_helpers.sh'

# MariaDB's own Linux release, cut down and given a stand-in libsystemd by static/mariadb (which the root build.sh runs
# first) - for the Intel models only
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/bin/mariadbd" ] || [ ! -f "${STATIC_PATH}/lib/libsystemd.so.0" ]; then
        abort "MariaDB not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
    fi

    mkdir -p binaries
    cp -r "${STATIC_PATH}" binaries/mariadb

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
