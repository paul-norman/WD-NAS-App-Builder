#!/bin/bash
. '../build_helpers.sh'

# Some models use AMD64 architecture and others use ARM
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

# The build machine's own Go (amd64), which compiles the test server for every architecture
HOST_GO_FILE="go${APP_UPSTREAM_VERSION}.linux-amd64.tar.gz"

if ! download "https://go.dev/dl/${HOST_GO_FILE}" "${HOST_GO_FILE}"; then
    abort "Go ${APP_UPSTREAM_VERSION} could not be downloaded for the build machine"
fi

rm -rf host-go
mkdir host-go
tar -xzf "${HOST_GO_FILE}" -C host-go --strip-components=1
rm -f "${HOST_GO_FILE}"
HOST_GO="$(pwd)/host-go/bin/go"

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Go's names for them: its 32-bit ARM build (armv6l) runs on the ARM models' ARMv7 processors; programs built for
    # those use ARMv7's instructions (GOARM=7)
    GO_ARCH="${ARCH}"
    GO_TARGET="GOARCH=${ARCH}"

    if [ "${ARCH}" = 'armhf' ]; then
        GO_ARCH='armv6l'
        GO_TARGET='GOARCH=arm GOARM=7'
    fi

    GO_REPO="https://go.dev/dl/go${APP_UPSTREAM_VERSION}.linux-${GO_ARCH}.tar.gz"

    # Make a directory for the files
    mkdir -p binaries
    cd binaries

    # Download and extract the right version of Go
    wget ${GO_REPO} -O go.tar.gz

    # Extract the data
    if [ -f go.tar.gz ]; then
        tar -xf go.tar.gz
        rm go.tar.gz
        DIR=$(ls | head -n 1)

        if [ -d ${DIR} ] && [ "${DIR}" != '' ]; then
            mv ${DIR}/* .
            rm -rf ${DIR}
        else
            abort "$(pwd)/go.tar.gz could not be extracted"
        fi
    else
        abort "$(pwd)/go.tar.gz could not be downloaded"
    fi

    cd ../

    # Compile the test server now, so the NAS doesn't need to build it on every boot
    # (with the build machine's own Go - the ARM models' can't run on it)
    if ! (cd web/test_server && env CGO_ENABLED=0 GOOS=linux ${GO_TARGET} "${HOST_GO}" build -o ../../binaries/test_server main.go); then
        abort 'the test server could not be compiled'
    fi

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

rm -rf host-go

. '../build_helpers.sh'
