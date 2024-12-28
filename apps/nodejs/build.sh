#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[x64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armv7l]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	NODE_REPO="https://nodejs.org/dist/v${APP_VERSION}/node-v${APP_VERSION}-linux-${ARCH}.tar.xz"
	
	# Make a directory for the files
	mkdir -p binaries
	cd binaries
	
	# Download and extract the right version of Node.js
	wget ${NODE_REPO} -O nodejs.tar.xz
	
	# Extract the data
	if [ -f nodejs.tar.xz ]; then
		tar -xf nodejs.tar.xz
		rm nodejs.tar.xz
		DIR=$(ls | head -n 1)
		if [ -d ${DIR} ] && [ "${DIR}" != "" ]; then
			mv ${DIR}/* .
			rm -rf ${DIR}
		else
			abort "$(pwd)/nodejs.tar.xz could not be extracted"
		fi
	else
		abort "$(pwd)/nodejs.tar.xz could not be extracted"
	fi
	
	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"