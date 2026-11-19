#!/bin/bash
. '../build_helpers.sh'

# changedetection.io (in its own Python, with Patchright) and its run-as helper (changedetection_runas) are prepared by
# static/changedetection (which the root build.sh runs first) - for the Intel models only (several of its packages have
# no 32-bit ARM builds)
MODELS='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'

# Skip if no wanted model (MODEL_OVERRIDE)
if models_wanted ${MODELS}; then
    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/amd64"

    for file in python/bin/python3 python/lib/python3.14/site-packages/changedetectionio/__init__.py \
        python/lib/python3.14/site-packages/patchright/driver/node changedetection_runas version; do
        if [ ! -e "${STATIC_PATH}/${file}" ]; then
            how="set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh"
            abort "${file} not found in: ${STATIC_PATH} (${how} and run: ./build_static.sh ${APP_NAME} amd64)"
        fi
    done

    mkdir -p binaries
    cp -r "${STATIC_PATH}"/* binaries/

    # Build the archive for all models
    build ${MODELS} amd64

    # Clean up any mess
    rm -rf binaries
fi

# Cleanup
. '../build_helpers.sh'
