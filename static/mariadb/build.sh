#!/bin/bash

# MariaDB for the NAS: MariaDB's own Linux release (built for glibc 2.28+, the NAS has 2.31), checked against its
# published checksum, cut down to what a server needs (no test suite, Galera, or plugins needing libraries the NAS
# doesn't have) and stripped. Its server needs libsystemd only to tell systemd it's ready - which the NAS doesn't run -
# so a stand-in library is added, found through a fixed path (/usr/local/mysql/lib: the app links /usr/local/mysql to
# these files, which is also where MariaDB's release looks for its plugins, messages and character sets)

set -e
set -o pipefail
set -x

VERSION=11.8.9
SHA256=32f8871a2aa38b36aa418b7f4abc6fc0c6ef1ba5a45798cacb2afa52c8a6113b

ARCH=$(uname -m)
if [ ${ARCH} = "x86_64" ]; then
    ARCH="amd64"
else
	ARCH="armhf"
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/mariadb/${VERSION}/${ARCH}

# The programs kept: the server, and the client tools for managing, backing up and upgrading it
PROGRAMS="mariadbd mariadb mariadb-admin mariadb-dump mariadb-import mariadb-check mariadb-show mariadb-upgrade
	mariadb-tzinfo-to-sql mariadb-backup my_print_defaults resolveip"

# Libraries the NAS has (anything else a plugin needs rules it out)
SYSTEM_LIBS="libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libstdc++.so.6 libgcc_s.so.1 libcrypt.so.1
	ld-linux-x86-64.so.2"

function download() {
	cd ${BUILD_PATH}
	wget -q "https://archive.mariadb.org/mariadb-${VERSION}/bintar-linux-systemd-x86_64/mariadb-${VERSION}-linux-systemd-x86_64.tar.gz" -O mariadb.tar.gz
	echo "${SHA256}  mariadb.tar.gz" | sha256sum -c -
	mkdir release
	tar -xzf mariadb.tar.gz -C release --strip-components=1
}

# The stand-in for libsystemd: the three functions MariaDB's server calls, doing nothing (as with no systemd)
function build_libsystemd() {
	cd ${BUILD_PATH}
	cat > libsystemd.c <<'C'
int sd_notify(int unset_environment, const char *state) { return 0; }
int sd_notifyf(int unset_environment, const char *format, ...) { return 0; }
int sd_listen_fds_with_names(int unset_environment, char ***names) { return 0; }
C
	cat > libsystemd.map <<'MAP'
LIBSYSTEMD_209 { global: sd_notify; sd_notifyf; local: *; };
LIBSYSTEMD_227 { global: sd_listen_fds_with_names; } LIBSYSTEMD_209;
MAP
	gcc -O2 -fPIC -shared -o libsystemd.so.0 -Wl,-soname,libsystemd.so.0 -Wl,--version-script=libsystemd.map libsystemd.c
}

function assemble() {
	release=${BUILD_PATH}/release
	mkdir -p ${OUTPUT_PATH}/bin ${OUTPUT_PATH}/lib/plugin ${OUTPUT_PATH}/scripts
	for program in ${PROGRAMS}; do
		cp ${release}/bin/${program} ${OUTPUT_PATH}/bin/
	done
	cp ${release}/scripts/mariadb-install-db ${OUTPUT_PATH}/scripts/
	cp -r ${release}/share ${OUTPUT_PATH}/
	cp ${BUILD_PATH}/libsystemd.so.0 ${OUTPUT_PATH}/lib/

	# Only plugins that need nothing beyond the NAS's own libraries
	for plugin in ${release}/lib/plugin/*.so; do
		missing=""
		for lib in $(readelf -d "${plugin}" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
			case " $(echo ${SYSTEM_LIBS}) " in *" ${lib} "*) ;; *) missing="${missing} ${lib}" ;; esac
		done
		if [ -z "${missing}" ]; then
			cp "${plugin}" ${OUTPUT_PATH}/lib/plugin/
		else
			echo "Leaving out $(basename "${plugin}") (needs:${missing})"
		fi
	done

	strip ${OUTPUT_PATH}/bin/* ${OUTPUT_PATH}/lib/plugin/*.so ${OUTPUT_PATH}/lib/libsystemd.so.0
	# The server finds the stand-in libsystemd in /usr/local/mysql/lib
	patchelf --set-rpath /usr/local/mysql/lib ${OUTPUT_PATH}/bin/mariadbd
}

function run() {
	# Clean start
	if [ -d ${BUILD_PATH} ]; then
		rm -rf ${BUILD_PATH}
	fi
	mkdir -p ${BUILD_PATH}

	download
	build_libsystemd
	rm -rf ${OUTPUT_PATH}
	assemble
	du -sh ${OUTPUT_PATH}

	# Create a latest release file for ease of use in packages
	LATEST_PATH="$(dirname ${OUTPUT_PATH})"
	LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
	echo -e "\nCreating a latest release file: ${LATEST_PATH}"
	rm -f ${LATEST_PATH}
	printf "%s" "${VERSION}" > ${LATEST_PATH}

	chown -R 1000:1000 /data/packages;
}

run
