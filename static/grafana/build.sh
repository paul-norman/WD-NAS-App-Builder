#!/bin/bash

# Prepares Grafana for the NAS - for the Intel models and the ARM ones: its official release for each (a static program,
# its web interface and bundled plugins), trimmed of what the NAS doesn't need, the "Node Exporter Full" dashboard, plus
# fully static builds of the tools the app uses:
#  - sqlite3:    SQLite's shell, for safe backups of Grafana's database while it runs
#  - graf_runas: switches to Grafana's own user (the NAS has no su or similar) before running it

# The ARM models' parts are built on this (Intel) machine: the tools cross-compiled with Zig for their ARMv7 processors
# (hard-float), and every ARM program checked with QEMU's emulator.

set -e
set -o pipefail
set -x

VERSION=13.3.1
# Each architecture's release, as dl.grafana.com publishes its SHA256 (<file>.sha256)
GRAFANA_SHA256=6acf8939dd2f73332cbcafc27a33973fb1115b8867e7ffa3223c6e2ecbed8531
GRAFANA_ARMHF_SHA256=889d240c242195209b419498a0e4d54272645238c4582fe2b240419b97e42e06
# The data source plugins kept (each holds a program for its data source): Prometheus and Loki (the project's metrics
# and logs apps), and the databases the MariaDB and PostgreSQL apps provide. Others (Tempo, InfluxDB...) can be
# installed from Grafana's plugin catalogue
PLUGINS='prometheus loki mysql grafana-postgresql-datasource'
# "Node Exporter Full" (rfmoz, Apache-2.0), from grafana.com
DASHBOARD_REVISION=45
DASHBOARD_SHA256=184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
# The architectures built (each into packages/static/grafana/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build

# Compiles a fully static C program for an architecture (stripped): gcc for amd64, Zig for armhf.
#
# $1 arch The architecture (amd64 or armhf)
# $@      The compiler's other arguments
function cc_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        zig cc -target arm-linux-musleabihf -mcpu=cortex_a9 -O2 -static -s "$@"
    else
        gcc -O2 -static -s "$@"
    fi
}

# Runs a program built for an architecture here (an ARM one with QEMU's emulator, as a Cortex-A9 - the ARM models'
# processors' kind).
#
# $1 arch The architecture (amd64 or armhf)
# $@      The program and its arguments
function run_for() {
    local arch="$1"
    shift

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 "$@"
    else
        "$@"
    fi
}

# Downloads a file into the current folder and checks it against its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Downloads and trims Grafana's release for an architecture, into ./grafana.
#
# $1 arch The architecture (amd64 or armhf)
function build_grafana() {
    if [ "$1" = armhf ]; then
        sh /data/static/fetch.sh \
            "https://dl.grafana.com/oss/release/grafana-${VERSION}.linux-armv7.tar.gz" \
            grafana.tar.gz "${GRAFANA_ARMHF_SHA256}"
    else
        sh /data/static/fetch.sh \
            "https://dl.grafana.com/oss/release/grafana-${VERSION}.linux-amd64.tar.gz" \
            grafana.tar.gz "${GRAFANA_SHA256}"
    fi

    tar -xzf grafana.tar.gz
    rm grafana.tar.gz
    mv grafana-${VERSION} grafana
    cd grafana

    if [ "$1" = armhf ]; then
        arm-none-eabi-strip bin/grafana
    else
        strip bin/grafana
    fi

    # Not needed to run it: its documentation, packaging files, the API browser (/swagger), and the web interface's
    # source maps (only used for debugging in a browser). The plugins' own maps stay: they're part of their signatures
    rm -rf docs packaging tools Dockerfile plugins-bundled public/build-swagger
    find public -name '*.map' -delete

    # Only the plugins kept (whole: Grafana checks each one's signature)
    for plugin in data/plugins-bundled/*; do
        case " ${PLUGINS} " in
            *" $(basename "${plugin}") "*) ;;
            *) rm -rf "${plugin}" ;;
        esac
    done

    ls data/plugins-bundled
    cd ..
}

function build_dashboard() {
    fetch "https://grafana.com/api/dashboards/1860/revisions/${DASHBOARD_REVISION}/download" node-exporter-full.json ${DASHBOARD_SHA256}
}

# Builds SQLite's shell for an architecture, as ./sqlite-amalgamation-<version>/sqlite3.
#
# $1 arch The architecture (amd64 or armhf)
function build_sqlite() {
    fetch "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip" sqlite.zip ${SQLITE_SHA256}
    unzip -q sqlite.zip
    cd sqlite-amalgamation-${SQLITE_VERSION}
    # A static binary that looks up users loads the system's own NSS libraries at run time, and crashes when their glibc
    # isn't the one it was built with (e.g. after a firmware update): its shell looks up its user's home folder only for
    # ~/.sqliterc, so that's left to $HOME - and the build stops if any such lookup is left
    sed -i 's/pwent=getpwuid(uid)/pwent=(struct passwd *)0/' shell.c

    if grep -qE '\<(getpw|getgr|gethostby|getaddrinfo|getservby)[a-z_]*\(' shell.c sqlite3.c; then
        echo "SQLite's shell looks up users or hosts: a static build would need the NAS's own NSS libraries"

        exit 1
    fi
    cc_for "$1" -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o sqlite3
    cd ..
}

# Builds the run-as helper for an architecture in the current folder.
#
# $1 arch The architecture (amd64 or armhf)
function build_runas() {
    cat > graf_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: graf_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("graf_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("graf_runas: could not run the program");
	return 127;
}
C
    cc_for "$1" -o graf_runas graf_runas.c
}

function run() {
    local arch output usage

    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi

    for arch in ${ARCHES}; do
        mkdir -p ${BUILD_PATH}/${arch}
        cd ${BUILD_PATH}/${arch}
        build_grafana ${arch}
        build_dashboard
        build_sqlite ${arch}
        build_runas ${arch}

        output=/data/packages/static/grafana/${VERSION}/${arch}
        rm -rf ${output}
        mkdir -p ${output}/dashboards
        cp -r grafana ${output}/
        cp node-exporter-full.json ${output}/dashboards/
        cp sqlite-amalgamation-${SQLITE_VERSION}/sqlite3 graf_runas ${output}/
        run_for ${arch} ${output}/grafana/bin/grafana --version
        run_for ${arch} ${output}/sqlite3 :memory: 'select sqlite_version();'
        # (no arguments: it says how to use it, and fails - showing that it runs)
        usage="$(run_for ${arch} ${output}/graf_runas 2>&1 || true)"
        echo "${usage}" | grep -q 'Usage: graf_runas'
        du -sh ${output} ${output}/grafana/*
        # (each architecture's release is large: only one at a time)
        rm -rf ${BUILD_PATH}/${arch}
    done

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/grafana/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
