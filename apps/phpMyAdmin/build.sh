#!/bin/bash
. "../build_helpers.sh"

# Make a directory for the files
mkdir -p binaries
cd binaries

PMA_REPO="https://files.phpmyadmin.net/phpMyAdmin/${APKG_VERSION}/phpMyAdmin-${APKG_VERSION}-all-languages.tar.gz"

# Download and extract the right version of Go
wget ${PMA_REPO} -O pma.tar.gz

# Extract the data
if [ -f pma.tar.gz ]; then
	tar -xf pma.tar.gz
	rm pma.tar.gz
	DIR=$(ls | head -n 1)
	if [ -d ${DIR} ] && [ "${DIR}" != "" ]; then
		mv ${DIR}/* .
		rm -rf ${DIR}
	else
		abort "$(pwd)/pma.tar.gz could not be extracted"
	fi
else
	abort "$(pwd)/pma.tar.gz could not be downloaded"
fi

cd ../

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"
for ARCH in "${!MODELS[@]}"; do
	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
done

# Clean up any mess
rm -rf binaries

# Cleanup
. "../build_helpers.sh"