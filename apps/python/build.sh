#!/bin/bash
. '../build_helpers.sh'

# Python is a portable build (python-build-standalone - the builds uv uses), relocatable and depending only on the NAS's
# glibc (2.17 or newer), plus uv (a static program) for virtual environments and packages. Both are downloaded and checked
# against their checksums - for the Intel models and the ARM ones (python-build-standalone's and uv's own ARMv7 builds)
declare -A MODELS
MODELS[amd64]='MyCloudPR4100 MyCloudPR2100 WDMyCloudDL4100 WDMyCloudDL2100'
MODELS[armhf]='WDCloud WDMyCloud WDMyCloudMirror WDMyCloudEX4100 WDMyCloudEX2100 MyCloudEX2Ultra'

# The python-build-standalone release with this app's Python version, and each architecture's checksum (its release's
# SHA256SUMS)
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
PYTHON_ARMHF_SHA256=cc9d776d69bfa1b23708ea5ff12f1d095127cc87dcececc49252786db8bb64bb
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
UV_ARMHF_SHA256=b215398c886e8cc2cfa282fe346c02025957f8633b75a3d4fd848e0adda4eddd

for ARCH in "${!MODELS[@]}"; do
    # Skip architectures without a wanted model (MODEL_OVERRIDE)
    models_wanted ${MODELS[${ARCH}]} || continue

    # Each architecture's builds (python-build-standalone's and uv's names for them) and checksums
    if [ "${ARCH}" = armhf ]; then
        PYTHON_TARGET=armv7-unknown-linux-gnueabihf
        UV_TARGET=armv7-unknown-linux-musleabihf
        PYTHON_CHECKSUM="${PYTHON_ARMHF_SHA256}"
        UV_CHECKSUM="${UV_ARMHF_SHA256}"
    else
        PYTHON_TARGET=x86_64-unknown-linux-gnu
        UV_TARGET=x86_64-unknown-linux-musl
        PYTHON_CHECKSUM="${PYTHON_SHA256}"
        UV_CHECKSUM="${UV_SHA256}"
    fi

    PYTHON_FILE="cpython-${APP_UPSTREAM_VERSION}+${PYTHON_RELEASE}-${PYTHON_TARGET}-install_only_stripped.tar.gz"
    UV_FILE="uv-${UV_VERSION}-${UV_TARGET}.tar.gz"
    mkdir -p binaries
    cd binaries

    if ! download "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${PYTHON_FILE}" "${PYTHON_FILE}" \
        || ! download "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz" "${UV_FILE}"; then
        abort "Python ${APP_UPSTREAM_VERSION} or uv ${UV_VERSION} could not be downloaded"
    fi

    if ! echo "${PYTHON_CHECKSUM}  ${PYTHON_FILE}" | sha256sum -c - || ! echo "${UV_CHECKSUM}  ${UV_FILE}" | sha256sum -c -; then
        abort 'The downloads failed their checksum checks'
    fi

    tar -xzf "${PYTHON_FILE}"
    tar -xzf "${UV_FILE}"
    mv "uv-${UV_TARGET}/uv" "uv-${UV_TARGET}/uvx" python/bin/
    rm -rf "${PYTHON_FILE}" "${UV_FILE}" "uv-${UV_TARGET}"
    # Not needed: the terminal database (Python 3.14's prompt has its own; its folders also differ only in case, which a
    # Windows drive holding the repository can't store) and IDLE (needs a desktop)
    rm -rf python/share/terminfo python/lib/python3*/idlelib python/bin/idle3*
    # Packages installed into the app itself would be lost with its next update: pip points to virtual environments
    cp ../EXTERNALLY-MANAGED python/lib/python3*/
    cd ../

    # Build the archive for all models of this architecture
    build ${MODELS[${ARCH}]} ${ARCH}

    # Clean up any mess
    rm -rf binaries
done

# Cleanup
. '../build_helpers.sh'
