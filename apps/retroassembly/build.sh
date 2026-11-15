#!/bin/bash
. '../build_helpers.sh'

# RetroAssembly with its own Node.js, SQLite's shell (for backups), its run-as helper (retroassembly_runas) and the
# sample games are prepared by static/retroassembly (which the root build.sh runs first) - for the Intel models only:
# it needs Node.js 26, which has no build for the ARM models' 32-bit processors
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    for file in node retroassembly_runas sqlite3 retroassembly/dist/server/serve.js samples/samples.tsv; do
        if [ ! -e "${STATIC_PATH}/${file}" ]; then
            how="set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh"
            abort "${file} not found in: ${STATIC_PATH} (${how} and run: ./build_static.sh ${APP_NAME} amd64)"
        fi
    done

    mkdir -p binaries
    cp -r "${STATIC_PATH}"/* binaries/

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
