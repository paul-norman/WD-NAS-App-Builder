#!/bin/bash
. "../build_helpers.sh"

# Jellyfin 12+ and jellyfin-ffmpeg only publish 64-bit builds, so only the Intel models are supported
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"

FFMPEG_VERSION=8.1.3-1

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	JELLYFIN_REPO="https://repo.jellyfin.org/files/server/linux/stable/v${APP_VERSION}/${ARCH}/jellyfin_${APP_VERSION}-${ARCH}.tar.gz"
	FFMPEG_REPO="https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v${FFMPEG_VERSION}/jellyfin-ffmpeg_${FFMPEG_VERSION}_portable_linux64-gpl.tar.xz"

	# The libraries the portable releases need, built for the NAS's glibc by static/jellyfin (which the root build.sh
	# runs first). libe_sqlite3.so must match this Jellyfin version's bundled SQLite, so they are built per version
	STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_VERSION}/${ARCH}"
	for lib in libe_sqlite3.so libva.so.2 libva-drm.so.2 libdrm.so.2 vainfo; do
		if [ ! -f "${STATIC_PATH}/${lib}" ]; then
			abort "${lib} not found in: ${STATIC_PATH} (set VERSION=${APP_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH} - delete that folder first if it is from an older build)"
		fi
	done

	# Make a directory for the files
	mkdir -p binaries/ffmpeg/lib
	cd binaries

	# Download and extract Jellyfin (the server and its web client, with their own .NET runtime)
	JELLYFIN_FILE="jellyfin_${APP_VERSION}-${ARCH}.tar.gz"
	if ! download "${JELLYFIN_REPO}" "${JELLYFIN_FILE}" || ! tar -xzf "${JELLYFIN_FILE}" || [ ! -x jellyfin/jellyfin ]; then
		abort "Jellyfin could not be downloaded or extracted from: ${JELLYFIN_REPO}"
	fi
	rm "${JELLYFIN_FILE}"

	# Download and extract jellyfin-ffmpeg (ffmpeg and ffprobe)
	FFMPEG_FILE="jellyfin-ffmpeg_${FFMPEG_VERSION}_portable_linux64-gpl.tar.xz"
	if ! download "${FFMPEG_REPO}" "${FFMPEG_FILE}" || ! tar -xJf "${FFMPEG_FILE}" -C ffmpeg || [ ! -x ffmpeg/ffmpeg ]; then
		abort "jellyfin-ffmpeg could not be downloaded or extracted from: ${FFMPEG_REPO}"
	fi
	rm "${FFMPEG_FILE}"

	# Replace Jellyfin's SQLite (built for a newer glibc) and give ffmpeg its newer libva / libdrm
	cp "${STATIC_PATH}/libe_sqlite3.so" jellyfin/libe_sqlite3.so
	cp "${STATIC_PATH}/libva.so.2" "${STATIC_PATH}/libva-drm.so.2" "${STATIC_PATH}/libdrm.so.2" ffmpeg/lib/
	cp "${STATIC_PATH}/vainfo" ffmpeg/

	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
