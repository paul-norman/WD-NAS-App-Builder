#!/bin/bash
. "../build_helpers.sh"

# Kopia is an official static binary, downloaded from its releases (checked against their published checksums) - for the
# Intel models only
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"

RELEASE_URL="https://github.com/kopia/kopia/releases/download/v${APP_VERSION}"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	KOPIA_NAME="kopia-${APP_VERSION}-linux-x64"
	mkdir -p binaries
	cd binaries
	if ! download "${RELEASE_URL}/${KOPIA_NAME}.tar.gz" "${KOPIA_NAME}.tar.gz" || ! download "${RELEASE_URL}/checksums.txt" "kopia-${APP_VERSION}-checksums.txt"; then
		abort "Kopia ${APP_VERSION} could not be downloaded"
	fi
	if ! grep "  ${KOPIA_NAME}.tar.gz$" "kopia-${APP_VERSION}-checksums.txt" | sha256sum -c -; then
		abort "${KOPIA_NAME}.tar.gz failed its checksum check"
	fi
	tar -xzf "${KOPIA_NAME}.tar.gz"
	mv "${KOPIA_NAME}/kopia" kopia
	rm -rf "${KOPIA_NAME}" "${KOPIA_NAME}.tar.gz" "kopia-${APP_VERSION}-checksums.txt"
	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
