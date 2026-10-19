#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

RELEASE_URL="https://github.com/syncthing/syncthing/releases/download/v${APP_VERSION}"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Syncthing's name for the architecture
	ST_ARCH="amd64"
	if [ "$ARCH" = "armhf" ]; then
		ST_ARCH="arm"
	fi
	ST_NAME="syncthing-linux-${ST_ARCH}-v${APP_VERSION}"

	# Download, check against the release's published checksums and extract (Syncthing is a single static binary)
	mkdir -p binaries
	cd binaries
	if ! download "${RELEASE_URL}/${ST_NAME}.tar.gz" "${ST_NAME}.tar.gz" || ! download "${RELEASE_URL}/sha256sum.txt.asc" "syncthing-v${APP_VERSION}-sha256sum.txt.asc"; then
		abort "Syncthing ${APP_VERSION} could not be downloaded for: ${ST_ARCH}"
	fi
	if ! grep " ${ST_NAME}.tar.gz$" "syncthing-v${APP_VERSION}-sha256sum.txt.asc" | sha256sum -c -; then
		abort "${ST_NAME}.tar.gz failed its checksum check"
	fi
	tar -xzf "${ST_NAME}.tar.gz"
	mv "${ST_NAME}/syncthing" syncthing
	rm -rf "${ST_NAME}" "${ST_NAME}.tar.gz" "syncthing-v${APP_VERSION}-sha256sum.txt.asc"
	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
