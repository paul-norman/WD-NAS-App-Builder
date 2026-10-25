#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Tailscale's name for the architecture
	TS_ARCH="amd64"
	if [ "$ARCH" = "armhf" ]; then
		TS_ARCH="arm"
	fi
	TS_NAME="tailscale_${APP_UPSTREAM_VERSION}_${TS_ARCH}"
	TS_URL="https://pkgs.tailscale.com/stable/${TS_NAME}.tgz"

	# Download, check against the published checksum and extract (tailscale and tailscaled are static binaries)
	mkdir -p binaries
	cd binaries
	if ! download "${TS_URL}" "${TS_NAME}.tgz" || ! download "${TS_URL}.sha256" "${TS_NAME}.tgz.sha256"; then
		abort "Tailscale ${APP_UPSTREAM_VERSION} could not be downloaded for: ${TS_ARCH}"
	fi
	if ! echo "$(cat "${TS_NAME}.tgz.sha256")  ${TS_NAME}.tgz" | sha256sum -c -; then
		abort "${TS_NAME}.tgz failed its checksum check"
	fi
	tar -xzf "${TS_NAME}.tgz"
	mv "${TS_NAME}/tailscale" "${TS_NAME}/tailscaled" .
	rm -rf "${TS_NAME}" "${TS_NAME}.tgz" "${TS_NAME}.tgz.sha256"
	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
