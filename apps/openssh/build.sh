#!/bin/bash
. "../build_helpers.sh"

# OpenSSH is prepared by static/openssh (which the root build.sh runs first) - for the Intel models only
declare -A MODELS
MODELS[amd64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	# Prepared for exactly this app's version
	STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"
	for file in bin/sshd bin/ssh bin/sftp bin/ssh-keygen bin/seccomp_check libexec/sshd-session libexec/sshd-auth \
		libexec/sftp-server libexec-nosandbox/sshd-auth; do
		if [ ! -e "${STATIC_PATH}/${file}" ]; then
			abort "${file} not found in: ${STATIC_PATH} (set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh and run: ./build_static.sh ${APP_NAME} ${ARCH})"
		fi
	done
	mkdir -p binaries
	cp -r "${STATIC_PATH}"/* binaries/

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}

	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
