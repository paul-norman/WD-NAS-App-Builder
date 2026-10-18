#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
# TODO: Build statically linked binary for ARM
#MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	# The statically linked binaries are built beforehand by build_static.sh (the root build.sh runs it)
	STATIC_VERSION=$(cat "${REPO_PATH}/packages/static/${APP_NAME}/latest" 2>/dev/null)
	STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${STATIC_VERSION}/${ARCH}"
	if [ -z "${STATIC_VERSION}" ] || [ ! -f "${STATIC_PATH}/valkey-server" ] || [ ! -f "${STATIC_PATH}/valkey-cli" ]; then
		abort "statically linked ValKey not found in: ${STATIC_PATH} (run: ./build_static.sh ${APP_NAME} ${ARCH})"
	fi

	# Put the statically linked binaries into the binaries directory
	mkdir -p binaries
	cp "${STATIC_PATH}/valkey-cli" binaries/valkey-cli
	cp "${STATIC_PATH}/valkey-server" binaries/valkey-server

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
