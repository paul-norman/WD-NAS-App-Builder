#!/bin/bash
. "../build_helpers.sh"

# Adminer (adminer.php) and its run-as helper (adminer_runas) are prepared by static/adminer (which the root build.sh runs first) -
# for the Intel models only
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Prepared for exactly this app's version
	STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"
	for file in adminer.php adminer-plugins/redis.php adminer_runas; do
		if [ ! -e "${STATIC_PATH}/${file}" ]; then
			abort "${file} not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
		fi
	done
	mkdir -p binaries www
	cp "${STATIC_PATH}/adminer_runas" binaries/
	# (all that PHP's server serves: Adminer, and its driver plugins - next to it, where it looks for them)
	cp "${STATIC_PATH}/adminer.php" www/index.php
	cp -r "${STATIC_PATH}/adminer-plugins" www/

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries www
done

# Cleanup
. "../build_helpers.sh"
