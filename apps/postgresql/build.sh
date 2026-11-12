#!/bin/bash
. '../build_helpers.sh'

# PostgreSQL is built by static/postgresql (which the root build.sh runs first; its amd64 build makes both), with its
# libraries bundled: for the Intel models on Debian Bullseye, for the ARM ones with Debian's cross-compiler (with
# Debian's glibc too)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -x "${STATIC_PATH}/bin/postgres" ] || [ ! -x "${STATIC_PATH}/bin/pg_runas" ]; then
        abort "PostgreSQL not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} amd64)"
    fi

    mkdir -p binaries
    cp -r "${STATIC_PATH}" binaries/postgresql

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
