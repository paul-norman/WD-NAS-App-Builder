#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[x86_64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

COMPOSE_VERSION=5.6.0

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	ARCH1=$ARCH
	ARCH2=$ARCH
	if [ "$ARCH" = "armhf" ]; then
		ARCH1="armv7"
	fi
			
	DOCKER_REPO="https://download.docker.com/linux/static/stable/${ARCH}/docker-${APKG_VERSION}.tgz"
	COMPOSE_REPO="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH1}"
	
	# Make a directory for the files
	mkdir -p binaries
	cd binaries

	# Download and extract the right version of Docker
	wget ${DOCKER_REPO} -O docker.tar.gz

	# Extract the data
	if [ -f docker.tar.gz ]; then
		tar -xf docker.tar.gz --strip-components=1
		rm docker.tar.gz
	else
		abort "$(pwd)/docker.tar.gz could not be downloaded"
	fi
	
	# Download the right version of Docker Compose
	wget ${COMPOSE_REPO} -O docker-compose
	chmod +x docker-compose

	cd ../

	# Kernel modules for the Intel models (overlay, iptable_raw - one folder per model), built from WD's GPL source by
	# static/docker, which the root build.sh runs first. daemon.sh only loads them on the model and firmware they were
	# built for
	if [ "$ARCH" = "x86_64" ]; then
		STATIC_VERSION=$(cat "${REPO_PATH}/packages/static/${APP_NAME}/latest" 2>/dev/null)
		STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${STATIC_VERSION}/amd64"
		if [ -z "${STATIC_VERSION}" ] || [ ! -f "${STATIC_PATH}/firmware" ] || ! ls "${STATIC_PATH}"/*/overlay.ko > /dev/null 2>&1; then
			abort "kernel modules not found in: ${STATIC_PATH} (run: ./build_static.sh ${APP_NAME} amd64)"
		fi
		mkdir -p modules
		cp -r "${STATIC_PATH}/." modules/
	fi

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries modules
done

# Cleanup
. "../build_helpers.sh"
