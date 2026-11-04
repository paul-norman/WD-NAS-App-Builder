#!/bin/bash

# Prepares k3s (lightweight Kubernetes) for the NAS:
#  - k3s: its official static program (Kubernetes, containerd, runc, flannel and its own iptables in one file)
#  - kernel modules that WD's Intel kernels lack but Kubernetes needs, built from WD's own GPL source for one firmware
#    version, as static/docker does: the iptables matches and targets kube-proxy's rules use (comment, multiport,
#    statistic, mark / MARK, REJECT), the mangle table, and overlay (for containerd's overlayfs snapshotter)
# A module only fits the exact kernel it was built against, so each model gets its own build, and the k3s app only loads
# them on that model running exactly this firmware version

set -e
set -o pipefail
set -x

# k3s's version (its release is v<VERSION>+<K3S_RELEASE>), and the SHA256 of its amd64 program (sha256sum-amd64.txt)
VERSION=1.37.2
K3S_RELEASE=k3s1
K3S_SHA256=265b3ee6a3198ef14033c63ef46cbb32370d83795199fb6d1b01f21575eddbda
# The k3s-root release this k3s bundles (busybox, iptables... - VERSION_ROOT in k3s's scripts/version.sh): its source
# is listed for the releases (ci/sources/k3s.conf)
K3S_ROOT_VERSION=v0.15.3

# The WD firmware version (and the date in its GPL source file names, see https://download.wdc.com/gpl/)
FIRMWARE=5.33.102
GPL_DATE=20260401
KERNEL_VERSION=linux-4.14.22

# Models to build for (as named in WD's GPL file names)
#  - DL2100 is left out: WD's GPL archive for it is truncated, so its kernel source can't be extracted
MODELS='PR4100 PR2100 DL4100'

# The kernel options added (as modules), the configuration lines they may add (nothing else in WD's configuration may
# change, or the modules may not fit WD's kernel), and the modules copied. Not NF_CT_NETLINK (kube-proxy's clean-up of
# stale UDP connections): it changes what WD's own nf_conntrack module is built with
OPTIONS='OVERLAY_FS NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_MULTIPORT NETFILTER_XT_MATCH_STATISTIC
    NETFILTER_XT_MARK IP_NF_TARGET_REJECT IP_NF_MANGLE'
EXPECTED_CHANGES='CONFIG_IP_NF_MANGLE=m
CONFIG_IP_NF_TARGET_REJECT=m
CONFIG_NETFILTER_XT_MARK=m
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=m
CONFIG_NETFILTER_XT_MATCH_STATISTIC=m
CONFIG_NF_REJECT_IPV4=m
CONFIG_OVERLAY_FS=m'
MODULE_FILES='fs/overlayfs/overlay.ko net/netfilter/xt_comment.ko net/netfilter/xt_multiport.ko
    net/netfilter/xt_statistic.ko net/netfilter/xt_mark.ko net/ipv4/netfilter/nf_reject_ipv4.ko
    net/ipv4/netfilter/ipt_REJECT.ko net/ipv4/netfilter/iptable_mangle.ko'

# Each model is skipped when its modules already exist, so build_static.sh doesn't skip the whole build
CHECKS_OWN_OUTPUTS=yes

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/k3s/${VERSION}/${ARCH}

function build_k3s() {
    if [ -x "${OUTPUT_PATH}/k3s" ]; then
        echo "k3s ${VERSION} is already prepared"

        return
    fi

    mkdir -p "${OUTPUT_PATH}"
    cd "${BUILD_PATH}"
    sh /data/static/fetch.sh \
        "https://github.com/k3s-io/k3s/releases/download/v${VERSION}%2B${K3S_RELEASE}/k3s" k3s "${K3S_SHA256}"
    chmod 755 k3s
    ./k3s --version | grep -q "v${VERSION}+${K3S_RELEASE}"
    mv k3s "${OUTPUT_PATH}/k3s"
}

function build_model() {
    local model=$1
    local gpl_name="WDMyCloud_${model}_GPL_v${FIRMWARE}_${GPL_DATE}"
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

    cp .config .config.wd

    for option in ${OPTIONS}; do
        scripts/config --module "${option}"
    done

    make olddefconfig
    local changes="$(diff <(grep -v '^#' .config.wd | grep . | sort) <(grep -v '^#' .config | grep . | sort) \
        | grep '^[<>]' || true)"

    if [ "${changes}" != "$(printf '%s\n' "${EXPECTED_CHANGES}" | sed 's/^/> /')" ]; then
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
    cp ${MODULE_FILES} "${OUTPUT_PATH}/MyCloud${model}/"
    cd /
    rm -rf "${model_path}"
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_k3s

    for model in ${MODELS}; do
        local missing=''

        for file in ${MODULE_FILES}; do
            [ -f "${OUTPUT_PATH}/MyCloud${model}/$(basename "${file}")" ] || missing=yes
        done

        if [ -z "${missing}" ]; then
            echo "Kernel modules for ${model} (firmware ${FIRMWARE}) are already built"
            continue
        fi

        build_model "${model}"
    done

    # The firmware version the modules are only valid for
    printf '%s' "${FIRMWARE}" > ${OUTPUT_PATH}/firmware

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
