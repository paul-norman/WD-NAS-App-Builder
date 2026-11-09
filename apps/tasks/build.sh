#!/bin/bash
. '../build_helpers.sh'

# Nothing to download or build: the app is its scripts and its page, the same for every model
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}
done

# Cleanup
. '../build_helpers.sh'
