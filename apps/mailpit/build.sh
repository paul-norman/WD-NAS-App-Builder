#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[arm]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	MP_REPO="https://github.com/axllent/mailpit/releases/download/v${APKG_VERSION}/mailpit-linux-${ARCH}.tar.gz"
	
	# Make a directory for the files
	mkdir -p binaries
	cd binaries

	# Download and extract the right version of Mailpit
	wget ${MP_REPO} -O mailpit.tar.gz

	# Extract the data
	if [ -f mailpit.tar.gz ]; then
		tar -xf mailpit.tar.gz
		rm mailpit.tar.gz
		DIR=$(ls | head -n 1)
		if [ -d ${DIR} ] && [ "${DIR}" != "" ]; then
			mv ${DIR}/* .
			rm -rf ${DIR}
		fi
	else
		abort "$(pwd)/mailpit.tar.gz could not be downloaded"
	fi

	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"