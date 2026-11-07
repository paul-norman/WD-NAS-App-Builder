#!/bin/bash

# Prepares Scrutiny (the disks' SMART health, with history and alerts) for the NAS - for the Intel models only (InfluxDB 2,
# where Scrutiny keeps its history, has no 32-bit ARM build):
#  - scrutiny-web: its web interface and API, and its front end (the release's dist/)
#  - scrutiny-collector-metrics: reads each disk's SMART data with smartctl and sends it to the web interface
#  - influxd: InfluxDB 2, its time series database
#  - smartctl: smartmontools' SMART tool, fully static (Scrutiny reads its JSON output: smartctl 7 or later)
#  - scrutiny_runas: switches to Scrutiny's own user (the NAS has no su or similar) before running the web interface and
#    InfluxDB (the collector runs as root: reading SMART data needs it)
# Checked on the NAS's kind of processor (QEMU, as a Nehalem: no AVX - like the PR4100's Pentium N3710): InfluxDB starts,
# and Scrutiny sets it up and answers (the app's suite sends it a disk's SMART data).

set -e
set -o pipefail
set -x

VERSION=0.10.0
# Its release's files, as GitHub publishes their digests
SCRUTINY_WEB_SHA256=aef180aa5187f77567d670310a7574a90d09cbda19b72540134eb32cd66bcdb0
SCRUTINY_COLLECTOR_SHA256=d1d5180b10b2c183670c931c38ae149544627a0525640664b754d3a0fc48a5ad
SCRUTINY_FRONTEND_SHA256=344fe65088295f07d9edbc94f278dd4b09912c65a8b8958532f273c25b772a56
INFLUXDB_VERSION=2.9.1
# As InfluxData publishes it (<file>.sha256)
INFLUXDB_SHA256=762e4fc825c4386e0c5138e7c3f91fc778081db2bada1ec47066e786bf55d9ff
SMARTMONTOOLS_VERSION=7.5
# Smartmontools publishes MD5s: 38c38b0b82db7fc4906cdd50d15a7931 - checked to match
SMARTMONTOOLS_SHA256=690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/scrutiny/${VERSION}/amd64

function build_scrutiny() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/AnalogJ/scrutiny/releases/download/v${VERSION}/scrutiny-web-linux-amd64" \
        scrutiny-web "${SCRUTINY_WEB_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/AnalogJ/scrutiny/releases/download/v${VERSION}/scrutiny-collector-metrics-linux-amd64" \
        scrutiny-collector-metrics "${SCRUTINY_COLLECTOR_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/AnalogJ/scrutiny/releases/download/v${VERSION}/scrutiny-web-frontend.tar.gz" \
        frontend.tar.gz "${SCRUTINY_FRONTEND_SHA256}"
    chmod 755 scrutiny-web scrutiny-collector-metrics
    mkdir -p web
    tar -xzf frontend.tar.gz -C web
    [ -f web/dist/index.html ]
}

function build_influxdb() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://dl.influxdata.com/influxdb/releases/influxdb2-${INFLUXDB_VERSION}_linux_amd64.tar.gz" \
        influxdb.tar.gz "${INFLUXDB_SHA256}"
    tar -xzf influxdb.tar.gz
    mv influxdb2-${INFLUXDB_VERSION}/influxd influxd
}

function build_smartctl() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh \
        "https://github.com/smartmontools/smartmontools/releases/download/RELEASE_${SMARTMONTOOLS_VERSION//./_}/smartmontools-${SMARTMONTOOLS_VERSION}.tar.gz" \
        smartmontools.tar.gz "${SMARTMONTOOLS_SHA256}"
    tar -xzf smartmontools.tar.gz
    cd smartmontools-${SMARTMONTOOLS_VERSION}
    ./configure LDFLAGS=-static --without-libsystemd --without-systemdsystemunitdir --without-selinux --without-libcap-ng
    make -j "$(nproc)" smartctl
    strip smartctl
    mv smartctl ${BUILD_PATH}/smartctl
}

function build_runas() {
    cd ${BUILD_PATH}
    cat > scrutiny_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: scrutiny_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("scrutiny_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("scrutiny_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o scrutiny_runas scrutiny_runas.c
}

# Runs InfluxDB and Scrutiny as the NAS's processor would (no AVX), and checks Scrutiny sets InfluxDB up and answers.
function check() {
    local check=${BUILD_PATH}/check i=0
    local emulate='qemu-x86_64 -cpu Nehalem'

    mkdir -p ${check}/influxdb
    cat > ${check}/scrutiny.yaml <<EOF
version: 1
web:
  listen:
    host: 127.0.0.1
    port: 18091
  database:
    location: ${check}/scrutiny.db
  src:
    frontend:
      path: ${OUTPUT_PATH}/web/dist
  influxdb:
    host: 127.0.0.1
    port: 18093
    retention_policy: true
log:
  level: INFO
EOF
    ${emulate} ${OUTPUT_PATH}/influxd --bolt-path ${check}/influxdb/influxd.bolt --engine-path ${check}/influxdb/engine \
        --sqlite-path ${check}/influxdb/influxd.sqlite --http-bind-address 127.0.0.1:18093 --reporting-disabled \
        > ${check}/influxd.log 2>&1 &

    until curl -sf http://127.0.0.1:18093/health > /dev/null; do
        [ ${i} -lt 120 ] || { tail -n 20 ${check}/influxd.log; exit 1; }
        sleep 1
        i=$((i + 1))
    done

    ${emulate} ${OUTPUT_PATH}/scrutiny-web start --config ${check}/scrutiny.yaml > ${check}/web.log 2>&1 &
    i=0

    until curl -sf http://127.0.0.1:18091/api/health | grep -q '"success":true'; do
        [ ${i} -lt 120 ] || { tail -n 20 ${check}/web.log; exit 1; }
        sleep 1
        i=$((i + 1))
    done

    # Scrutiny set InfluxDB up (its first user, organisation and bucket: InfluxDB allows that only once), and serves its
    # front end
    curl -sf http://127.0.0.1:18093/api/v2/setup | grep -q '"allowed": false'
    curl -sf http://127.0.0.1:18091/web/ | grep -qi '<app-root'

    kill %2 %1
    wait || true
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_scrutiny
    build_influxdb
    build_smartctl
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cd ${BUILD_PATH}
    cp scrutiny-web scrutiny-collector-metrics influxd smartctl scrutiny_runas ${OUTPUT_PATH}/
    cp -r web ${OUTPUT_PATH}/

    for program in scrutiny-web scrutiny-collector-metrics influxd smartctl scrutiny_runas; do
        if ldd ${OUTPUT_PATH}/${program} 2>&1 | grep -q '=>'; then
            echo "${program} isn't static"

            exit 1
        fi
    done

    # (versions written to a file first: the checks read their first lines only)
    ${OUTPUT_PATH}/smartctl --version > version.txt
    head -n 1 version.txt
    grep -q "^smartctl ${SMARTMONTOOLS_VERSION} " version.txt
    ${OUTPUT_PATH}/influxd version > version.txt
    grep -q "^InfluxDB v${INFLUXDB_VERSION} " version.txt
    check
    du -sh ${OUTPUT_PATH}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/scrutiny/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
