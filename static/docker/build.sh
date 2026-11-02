#!/bin/bash

# Builds kernel modules that WD's Intel kernels lack but Docker needs, from WD's own GPL source for one firmware
# version:
#  - overlay.ko     - the overlay file system, so Docker can use the efficient overlay2 storage driver (instead of vfs)
#  - iptable_raw.ko - the iptables "raw" table, used by Docker 28+ to block access to unpublished container ports
# A module only fits the exact kernel it was built against, so each model gets its own build, and the Docker app only
# loads them on that model running exactly this firmware version (anything else falls back to vfs)

set -e
set -o pipefail
set -x

# The WD firmware version (and the date in its GPL source file names, see https://download.wdc.com/gpl/)
VERSION=5.33.102
GPL_DATE=20260401
KERNEL_VERSION=linux-4.14.22

# Models to build for (as named in WD's GPL file names)
#  - DL2100 is left out: WD's GPL archive for it is truncated, so its kernel source can't be extracted
MODELS='PR4100 PR2100 DL4100'

# Each model is skipped when its modules already exist, so build_static.sh doesn't skip the whole build
CHECKS_OWN_OUTPUTS=yes

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/docker/${VERSION}/${ARCH}

function build_model() {
    local model=$1
    local gpl_name="WDMyCloud_${model}_GPL_v${VERSION}_${GPL_DATE}"
    local model_path="${BUILD_PATH}/${model}"

    mkdir -p "${model_path}"
    cd "${model_path}"

    # Download (up to 1.6GB) and keep only the kernel source
    wget -q "https://download.wdc.com/gpl/${gpl_name}.tar.gz" -O gpl.tar.gz
    tar -xzf gpl.tar.gz "${gpl_name}/kernel/${KERNEL_VERSION}.tar.gz"
    rm gpl.tar.gz
    tar -xzf "${gpl_name}/kernel/${KERNEL_VERSION}.tar.gz"
    rm -rf "${gpl_name}"
    cd ${KERNEL_VERSION}

    # Match WD's own kernel build (see xbuild.sh in the kernel source): its in-tree .config, build flags and identity
    export ARCH=x86_64 KCFLAGS='-DWD_CUSTOMIZE' KBUILD_BUILD_USER=kman KBUILD_BUILD_HOST=kmachine

    # Only add the two modules - nothing else in the configuration may change, or the modules may not fit WD's kernel
    cp .config .config.wd
    scripts/config --module OVERLAY_FS --module IP_NF_RAW
    make olddefconfig
    local changes="$(diff <(grep -v '^#' .config.wd | grep . | sort) <(grep -v '^#' .config | grep . | sort) | grep '^[<>]' || true)"

    if [ "${changes}" != "$(printf '> CONFIG_IP_NF_RAW=m\n> CONFIG_OVERLAY_FS=m')" ]; then
        echo "Unexpected kernel configuration changes for ${model}:"
        echo "${changes}"

        exit 1
    fi

    # A full build, so that modpost checks every symbol the modules use is exported by WD's kernel
    make -j"$(nproc)" bzImage modules 2>&1 | tee build.log

    if grep -q 'undefined!' build.log; then
        echo "Modules use symbols that WD's ${model} kernel doesn't export"

        exit 1
    fi

    # Copy to output (named like the NAS's own model file, without any "WD" prefix) and free the space
    mkdir -p "${OUTPUT_PATH}/MyCloud${model}"
    cp fs/overlayfs/overlay.ko net/ipv4/netfilter/iptable_raw.ko "${OUTPUT_PATH}/MyCloud${model}/"
    cd /
    rm -rf "${model_path}"
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    for model in ${MODELS}; do
        if [ -f "${OUTPUT_PATH}/MyCloud${model}/overlay.ko" ] && [ -f "${OUTPUT_PATH}/MyCloud${model}/iptable_raw.ko" ]; then
            echo "Kernel modules for ${model} (firmware ${VERSION}) are already built"
            continue
        fi
        build_model "${model}"
    done

    # The firmware version the modules are only valid for
    printf '%s' "${VERSION}" > ${OUTPUT_PATH}/firmware

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages
}

run
