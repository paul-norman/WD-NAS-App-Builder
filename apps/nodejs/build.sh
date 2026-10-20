#!/bin/bash
. "../build_helpers.sh"

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[x64]="MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100"
# Node.js 24+ no longer publishes 32-bit ARM (armv7l) builds
#MODELS[armv7l]="WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra"

# pnpm: its native program (pnpm 11+ is no longer plain JavaScript - its package only wraps the program, and would
# download it on first use), installed as npm's own install script would. Both checked against npm's published integrity
PNPM_VERSION=12.14.0
PNPM_INTEGRITY="sha512-wYum2HmT09Fky16JSPMrLAbuhUSH4GzY2GeBNC+z5btGNDZwNHEehoArqpw3vqkGzhkprQjXCITJfYAd8TOJpg=="
PNPM_EXE_INTEGRITY="sha512-F6K8e/jWxiuEYJaQtRRUG9ynBSTEHa+t7Lf86MKuOO5UA7WVVMbi+oB8nY6iKW++ncWS2yG6T9faXZGxqNsfoQ=="

# Checks a downloaded file against an npm integrity value (sha512-<base64>)
check_integrity() {
	local expected="$(echo "${2#sha512-}" | base64 -d | od -An -tx1 | tr -d ' \n')"
	[ "$(sha512sum "$1" | cut -d ' ' -f 1)" = "${expected}" ]
}

for ARCH in "${!MODELS[@]}"; do
	# Skip architectures without a wanted model (MODEL_OVERRIDE)
	models_wanted ${MODELS[${ARCH}]} || continue

	NODE_REPO="https://nodejs.org/dist/v${APP_VERSION}/node-v${APP_VERSION}-linux-${ARCH}.tar.xz"
	
	# Make a directory for the files
	mkdir -p binaries
	cd binaries
	
	# Download and extract the right version of Node.js
	wget ${NODE_REPO} -O nodejs.tar.xz
	
	# Extract the data
	if [ -f nodejs.tar.xz ]; then
		tar -xf nodejs.tar.xz
		rm nodejs.tar.xz
		DIR=$(ls | head -n 1)
		if [ -d ${DIR} ] && [ "${DIR}" != "" ]; then
			mv ${DIR}/* .
			rm -rf ${DIR}
		else
			abort "$(pwd)/nodejs.tar.xz could not be extracted"
		fi
	else
		abort "$(pwd)/nodejs.tar.xz could not be extracted"
	fi
	
	# pnpm: the wrapper package (with the extras the program uses, e.g. for building native modules) where npm installs
	# global packages, with its placeholder pnpm replaced by the native program (its pn, pnpx and pnx are small scripts
	# that hand over to it, e.g. pnpx runs pnpm dlx)
	if [ "${ARCH}" = "x64" ]; then
		if ! download "https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_VERSION}.tgz" "pnpm-${PNPM_VERSION}.tgz" \
			|| ! check_integrity "pnpm-${PNPM_VERSION}.tgz" "${PNPM_INTEGRITY}" \
			|| ! download "https://registry.npmjs.org/@pnpm/exe.linux-x64/-/exe.linux-x64-${PNPM_VERSION}.tgz" "pnpm-exe-${PNPM_VERSION}.tgz" \
			|| ! check_integrity "pnpm-exe-${PNPM_VERSION}.tgz" "${PNPM_EXE_INTEGRITY}"; then
			abort "pnpm ${PNPM_VERSION} could not be downloaded, or doesn't match npm's published integrity"
		fi
		mkdir -p lib/node_modules/pnpm pnpm-exe
		tar -xzf "pnpm-${PNPM_VERSION}.tgz" -C lib/node_modules/pnpm --strip-components=1
		tar -xzf "pnpm-exe-${PNPM_VERSION}.tgz" -C pnpm-exe --strip-components=1
		cp pnpm-exe/pnpm lib/node_modules/pnpm/pnpm
		# Its pn, pnpx and pnx scripts are shebang-less (only for the native program's sake, which doesn't replace them
		# here), so they get one - otherwise the packaging wouldn't mark them executable, nor could programs run them
		for name in pn pnpx pnx; do
			sed -i '1i #!/bin/sh' "lib/node_modules/pnpm/${name}"
		done
		chmod 755 lib/node_modules/pnpm/pnpm lib/node_modules/pnpm/pn lib/node_modules/pnpm/pnpx lib/node_modules/pnpm/pnx
		for name in pnpm pn pnpx pnx; do
			ln -sf "../lib/node_modules/pnpm/${name}" "bin/${name}"
		done
		rm -rf pnpm-exe "pnpm-${PNPM_VERSION}.tgz" "pnpm-exe-${PNPM_VERSION}.tgz"
	fi

	cd ../

	# Build the archive for all models of this architecture
	build ${MODELS[${ARCH}]} ${ARCH}
	
	# Clean up any mess
	rm -rf binaries
done

# Cleanup
. "../build_helpers.sh"
