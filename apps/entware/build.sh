#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Entware's name for the architecture
	if [ "$ARCH" = "amd64" ]; then
		ENTWARE_ARCH="x64-k3.2"
	else
		ENTWARE_ARCH="armv7sf-k3.2"
	fi

	# Bundle Entware's official installer (fetched over HTTPS here), which install.sh runs for fresh installs
	mkdir -p installer
	if ! wget -q "https://bin.entware.net/${ENTWARE_ARCH}/installer/generic.sh" -O installer/generic.sh || ! grep -q opkg installer/generic.sh; then
		abort "Entware's installer could not be downloaded for: ${ENTWARE_ARCH}"
	fi

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf installer
done

# Cleanup
. "../build_helpers.sh"
