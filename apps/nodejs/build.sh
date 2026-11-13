#!/bin/bash
. '../build_helpers.sh'

# Node.js is prepared by static/nodejs (which the root build.sh runs first) - for the Intel models its official build,
# for the ARM ones built from its source (Node.js publishes no 32-bit ARM builds since version 24)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

# pnpm: on the Intel models its native program (pnpm 11+ is no longer plain JavaScript - its package only wraps the
# program, and would download it on first use), installed as npm's own install script would. Both checked against npm's
# published integrity
PNPM_VERSION=12.17.0
PNPM_INTEGRITY='sha512-uNIj6+wEtYContIG2qcdG8y2oe4dUu+pXMOw23UnFWHfjw2OLEOt05xewIAYr3qKlRCOcJD5Win4hye3pA/VPQ=='
PNPM_EXE_INTEGRITY='sha512-vQAusDzMofc/Ee4KOUYjE6FWeHOlMGQyvhR7W39QSamVeJWS16co/n+bhjdjwjI3UFh8IWOpamvTS+b4lvQUog=='
# On the ARM models pnpm 10, its last plain JavaScript version (pnpm publishes no native program for 32-bit ARM)
PNPM_ARM_VERSION=10.34.9
PNPM_ARM_INTEGRITY='sha512-9JtajqD97bRLs8DB1ldQkqU8KVDZW3rRXfEfF5dId6LeOgHAfpNOmyjOcW5RwJqUlixzBtCb4uHksYqMh2L9Mg=='

# Checks a downloaded file against an npm integrity value.
#
# $1 file      The file
# $2 integrity Its integrity value (sha512-<base64>)
#
# Returns 0 if it matches
check_integrity() {
    local expected="$(echo "${2#sha512-}" | base64 -d | od -An -tx1 | tr -d ' \n')"
    [ "$(sha512sum "$1" | cut -d ' ' -f 1)" = "${expected}" ]
}

# pnpm's native program (Intel): the wrapper package (with the extras the program uses, e.g. for building native
# modules) where npm installs global packages, with its placeholder pnpm replaced by the native program (its pn, pnpx
# and pnx are small scripts that hand over to it, e.g. pnpx runs pnpm dlx). Run in the binaries folder.
install_pnpm_native() {
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
}

# pnpm 10 (ARM): plain JavaScript, installed where npm installs global packages, with its pnpm and pnpx linked as npm
# links them. Run in the binaries folder.
install_pnpm_javascript() {
    if ! download "https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_ARM_VERSION}.tgz" "pnpm-${PNPM_ARM_VERSION}.tgz" \
        || ! check_integrity "pnpm-${PNPM_ARM_VERSION}.tgz" "${PNPM_ARM_INTEGRITY}"; then
        abort "pnpm ${PNPM_ARM_VERSION} could not be downloaded, or doesn't match npm's published integrity"
    fi

    mkdir -p lib/node_modules/pnpm
    tar -xzf "pnpm-${PNPM_ARM_VERSION}.tgz" -C lib/node_modules/pnpm --strip-components=1
    chmod 755 lib/node_modules/pnpm/bin/pnpm.cjs lib/node_modules/pnpm/bin/pnpx.cjs
    ln -sf ../lib/node_modules/pnpm/bin/pnpm.cjs bin/pnpm
    ln -sf ../lib/node_modules/pnpm/bin/pnpx.cjs bin/pnpx
    rm -f "pnpm-${PNPM_ARM_VERSION}.tgz"
}

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Prepared for exactly this app's version
    STATIC_PATH="${REPO_PATH}/packages/static/${APP_NAME}/${APP_UPSTREAM_VERSION}/${ARCH}"

    for file in bin/node bin/npm bin/npx lib/node_modules/npm/package.json; do
        if [ ! -e "${STATIC_PATH}/${file}" ]; then
            how="set VERSION=${APP_UPSTREAM_VERSION} in static/${APP_NAME}/build.sh"
            abort "${file} not found in: ${STATIC_PATH} (${how} and run: ./build_static.sh ${APP_NAME} amd64)"
        fi
    done

    mkdir -p binaries
    cp -a "${STATIC_PATH}"/. binaries/
    cd binaries

    if [ "${ARCH}" = 'amd64' ]; then
        install_pnpm_native
    else
        install_pnpm_javascript
    fi

    cd ../

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
