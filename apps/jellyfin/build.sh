#!/bin/bash
. "../build_helpers.sh"

# Update these and the version in `apkg.rc` for each build
Jellyfin="10.8.12-1"
JellyfinMain="10.8.12"
Ffmpeg="6_6.0-8"
FfmpegMain="6.0-8"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
MODELS[armhf]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

for ARCH in "${!MODELS[@]}"; do
	JELLYFIN_REPO="https://repo.jellyfin.org/releases/server/debian/versions/stable/server/${JellyfinMain}/jellyfin-server_${Jellyfin}_${ARCH}.deb"
	JELLYFIN_WEB_REPO="https://repo.jellyfin.org/releases/server/debian/versions/stable/web/${JellyfinMain}/jellyfin-web_${Jellyfin}_all.deb"
	FFMPEG_REPO="https://repo.jellyfin.org/releases/server/debian/versions/jellyfin-ffmpeg/${FfmpegMain}/jellyfin-ffmpeg${Ffmpeg}-bullseye_${ARCH}.deb"
	
	# Make a directory for the files
	mkdir -p binaries
	cd binaries
	
	# Download and extract the right version of Jellyfin
	wget ${JELLYFIN_REPO} -O jellyfin.deb
	
	# Extract the archive
	if [ -f jellyfin.deb ]; then
		ar x jellyfin.deb
		rm jellyfin.deb
		rm debian-binary
	else
		abort "$(pwd)/jellyfin.deb could not be extracted"
	fi
	
	# Extract the data
	if [ -f data.tar.xz ]; then
		tar -xf data.tar.xz
		rm data.tar.xz
		rm control.tar.xz
	else
		abort "$(pwd)/data.tar.xz could not be extracted"
	fi
	
	# Make a subdirectory to store FFMPEG
	mkdir -p ffmpeg
	cd ffmpeg
	
	# TODO: try to build this statically
	# Download and extract the right version of FFMPEG
	#wget ${FFMPEG_REPO} -O ffmpeg.deb
	
	# Extract the archive
	#if [ -f ffmpeg.deb ]; then
	#	ar x ffmpeg.deb
	#	rm ffmpeg.deb
	#	rm debian-binary
	#else
	#	abort "$(pwd)/ffmpeg.deb could not be extracted"
	#fi

	# Extract the data
	#if [ -f data.tar.xz ]; then
	#	tar -xf data.tar.xz
	#	rm data.tar.xz
	#	rm control.tar.xz
	#else
	#	abort "$(pwd)/data.tar.xz could not be extracted"
	#fi
	
	# For now we'll just use generic statically linked FFMPEG
	wget "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ARCH}-static.tar.xz" -O ffmpeg.tar.xz
	if [ -f ffmpeg.tar.xz ]; then
		tar -xf ffmpeg.tar.xz
		rm ffmpeg.tar.xz
		DIR=$(ls | head -n 1)
		mv ${DIR} bin
	else
		abort "$(pwd)/ffmpeg.tar.xz could not be extracted"
	fi
	
	# Make a subdirectory to store Jellyfin Web
	cd ../
	mkdir -p jellyfin-web
	cd jellyfin-web
	
	# Download and extract the right version of FFMPEG
	wget ${JELLYFIN_WEB_REPO} -O jellyfinweb.deb
	
	# Extract the archive
	if [ -f jellyfinweb.deb ]; then
		ar x jellyfinweb.deb
		rm jellyfinweb.deb
		rm debian-binary
	else
		abort "$(pwd)/jellyfinweb.deb could not be extracted"
	fi

	# Extract the data
	if [ -f data.tar.xz ]; then
		tar -xf data.tar.xz
		rm data.tar.xz
		rm control.tar.xz
	else
		abort "$(pwd)/data.tar.xz could not be extracted"
	fi
	
	cd ../../
	
	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"