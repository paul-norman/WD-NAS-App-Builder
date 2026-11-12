#!/bin/bash
. '../build_helpers.sh'

# Python (python-build-standalone, relocatable, using the NAS's own glibc) and uv are prepared by static/python (which
# the root build.sh runs first; its amd64 build makes both) - for the Intel models and the ARM ones (Python with its own
# launcher, laid out for their kernels' large memory pages; no uv, whose ARM release isn't)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    if [ ! -e "${STATIC_PATH}/python/bin/python3" ]; then
        abort "Python not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} amd64)"
    fi

    mkdir -p binaries
    cp -a "${STATIC_PATH}/python" binaries/

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
