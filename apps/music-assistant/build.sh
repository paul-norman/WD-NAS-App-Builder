#!/bin/bash
. "../build_helpers.sh"

# Music Assistant (with its own Python), ffmpeg, ffprobe and the run-as helper (ma_runas) are prepared by
# static/music-assistant (which the root build.sh runs first) - for the Intel models only
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Prepared for exactly this app's version
	STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"
	for file in python/bin/python3 ma_runas ffmpeg ffprobe; do
		if [ ! -e "${STATIC_PATH}/${file}" ]; then
			abort "${file} not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
		fi
	done
	mkdir -p binaries
	# (its Python has symbolic links: kept as links)
	cp -a "${STATIC_PATH}"/* binaries/

	# Music Assistant's providers whose packages were left out (on-device AI models need AVX2 and PyTorch, which no WD
	# NAS has): without them it would try to install those packages whenever they're set up - Smart Fades by default -
	# and fail. Found from each provider's requirements, with the app's own Python (portable: it runs here too)
	PROVIDERS="binaries/python/lib/python3.14/site-packages/music_assistant/providers"
	UNUSABLE="$(binaries/python/bin/python3 -I -c '
import glob, json, re, sys
from importlib.metadata import version, PackageNotFoundError
for manifest in sorted(glob.glob(sys.argv[1] + "/*/manifest.json")):
    for requirement in json.load(open(manifest)).get("requirements", []):
        try:
            version(re.split(r"[=<>!~\[ @]", requirement)[0])
        except PackageNotFoundError:
            print(manifest.split("/")[-2])
            break
' "${PROVIDERS}")" || abort "Could not check Music Assistant's providers"
	for provider in ${UNUSABLE}; do
		echo "Leaving out Music Assistant's ${provider} provider (its packages aren't included)"
		rm -rf "${PROVIDERS:?}/${provider}"
	done

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
