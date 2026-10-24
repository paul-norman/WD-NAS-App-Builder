#!/bin/bash

# Prepares Grafana for the NAS: its official release (a static program, its web interface and bundled plugins), trimmed
# of what the NAS doesn't need, the "Node Exporter Full" dashboard, plus fully static builds of the tools the app uses:
#  - sqlite3:    SQLite's shell, for safe backups of Grafana's database while it runs
#  - graf_runas: switches to Grafana's own user (the NAS has no su or similar) before running it

set -e
set -o pipefail
set -x

VERSION=13.2.4
GRAFANA_SHA256=c48765988fd88572607e4ea670251af8a8e64ab3e360d0f3cf67a6f3587b92ab
# The data source plugins kept (each holds a program for its data source): Prometheus and Loki (the project's metrics and
# logs apps), and the databases the MariaDB and PostgreSQL apps provide. Others (Tempo, InfluxDB...) can be installed from
# Grafana's plugin catalogue
PLUGINS="prometheus loki mysql grafana-postgresql-datasource"
# "Node Exporter Full" (rfmoz, Apache-2.0), from grafana.com
DASHBOARD_REVISION=45
DASHBOARD_SHA256=184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# (SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match)
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/grafana/${VERSION}/${ARCH}

# Downloads a file and checks it against its SHA256
function fetch() {
	cd ${BUILD_PATH}
	wget -q "$1" -O "$2"
	echo "$3  $2" | sha256sum -c -
}

function build_grafana() {
	fetch "https://dl.grafana.com/oss/release/grafana-${VERSION}.linux-amd64.tar.gz" grafana.tar.gz ${GRAFANA_SHA256}
	tar -xzf grafana.tar.gz
	rm grafana.tar.gz
	mv grafana-${VERSION} grafana
	cd grafana
	strip bin/grafana
	# Not needed to run it: its documentation, packaging files, the API browser (/swagger), and the web interface's source
	# maps (only used for debugging in a browser). The plugins' own maps stay: they're part of their signatures
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
}

function build_dashboard() {
	fetch "https://grafana.com/api/dashboards/1860/revisions/${DASHBOARD_REVISION}/download" node-exporter-full.json ${DASHBOARD_SHA256}
}

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
	gcc -O2 -static -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -o sqlite3
	strip sqlite3
}

function build_runas() {
	cd ${BUILD_PATH}
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
	gcc -O2 -static -o graf_runas graf_runas.c
	strip graf_runas
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	build_grafana
	build_dashboard
	build_sqlite
	build_runas

	rm -rf ${OUTPUT_PATH}
	mkdir -p ${OUTPUT_PATH}/dashboards
	cp -r ${BUILD_PATH}/grafana ${OUTPUT_PATH}/
	cp ${BUILD_PATH}/node-exporter-full.json ${OUTPUT_PATH}/dashboards/
	cp ${BUILD_PATH}/sqlite-amalgamation-${SQLITE_VERSION}/sqlite3 ${BUILD_PATH}/graf_runas ${OUTPUT_PATH}/
	${OUTPUT_PATH}/grafana/bin/grafana --version
	du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/grafana/*

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
