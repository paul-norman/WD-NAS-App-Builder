#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
# TODO: Build statically linked binary for ARM
#MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	# Build the statically linked binary if it doesn't already exist
	if [ ! -d "${REPO_PATH}/packages/static/${APP_NAME}" ]; then
		/bin/bash ../../build_static.sh ${APP_NAME}
	fi
	
	# Put the statically linked binary into the binaries directory
	mkdir -p binaries
	STATIC_VERSION=$(cat "${REPO_PATH}/packages/static/${APP_NAME}/latest")
	cp ${REPO_PATH}/packages/static/${APP_NAME}/${STATIC_VERSION}/${ARCH}/nano binaries/nano

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"