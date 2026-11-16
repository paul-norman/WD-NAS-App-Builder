#!/bin/bash

# Prepares linkding for the NAS (the Intel models): its source as tagged (GitHub's archive of its tag, pinned here - it
# publishes no other release), with its own Python (a portable, relocatable build) and the packages its lock file names
# (each checked against the lock's checksums), its web interface built (with Node.js, from its own lock file) and
# gathered as its web server serves it, plus:
#  - linkding_runas: switches to linkding's own user (the NAS has no su or similar) before running it
#
# Left out: its page snapshots (they need a Chromium browser) and its PostgreSQL support (it keeps its data in SQLite).
# Its web server's settings (uwsgi.ini) lose the parts for its Docker image: the user it switches to (the app starts it
# as linkding's own), its PID file and its statistics port.

set -e
set -o pipefail
set -x

VERSION=1.47.0
# GitHub's archive of its tag
LINKDING_SHA256=6ada53ec63abef00a02dac80444b6469d83bb3e9e9d3a40e70c638aa818bf48b
# Its Python: 3.13, as its own image (uWSGI's builds for it are tried and tested)
PYTHON_VERSION=3.13.18
PYTHON_RELEASE=20261026
PYTHON_SHA256=df15fe60d3ff55bf9dcf25824b5572756bb8816ff93865a273d3301d7066a8b7
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# Only to build its web interface (as Node.js's SHASUMS256.txt publishes it)
NODE_VERSION=26.13.1
NODE_SHA256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
# The newest glibc symbol version the NAS has (OS5: glibc 2.31)
NAS_GLIBC=2.31

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/linkding/${VERSION}/amd64

# Downloads a file into ${BUILD_PATH} and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Prepares the tools: Node.js (in the PATH) and uv.
function build_tools() {
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    export PATH="${BUILD_PATH}/node/bin:${PATH}"
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
}

# Puts linkding's source into ${BUILD_PATH}/linkding, with its web interface built.
function build_source() {
    fetch "https://github.com/sissbruecker/linkding/archive/refs/tags/v${VERSION}.tar.gz" linkding.tar.gz \
        ${LINKDING_SHA256}
    mkdir -p linkding
    tar -xzf linkding.tar.gz -C linkding --strip-components=1
    grep -qx "${VERSION}" linkding/version.txt

    cd linkding
    npm ci --no-audit --no-fund
    npm run build
}

# Installs its Python and its packages - from its lock file, as wheels for the NAS's glibc, but for uWSGI (built here
# with this machine's compiler: python-build-standalone names the one it was built with; linked to its libpython, which
# it finds through LD_LIBRARY_PATH when it runs) - into ${BUILD_PATH}/python.
function build_python() {
    local uv=${BUILD_PATH}/uv-x86_64-unknown-linux-musl/uv
    local lib=${BUILD_PATH}/python/lib/python3.13

    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    tar -xzf python.tar.gz

    cd ${BUILD_PATH}/linkding
    ${uv} export --frozen --no-dev --no-emit-project --format requirements-txt -o ${BUILD_PATH}/requirements.txt
    CC=gcc LDFLAGS="-L${BUILD_PATH}/python/lib" ${uv} pip install --python ${BUILD_PATH}/python/bin/python3 \
        --break-system-packages \
        --python-platform x86_64-manylinux_${NAS_GLIBC/./_} --require-hashes -r ${BUILD_PATH}/requirements.txt

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS),
    # and the terminal database - whose folders differ only in case, which a Windows drive holding the repository can't
    # store
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${lib}/site-packages/pip \
        ${lib}/site-packages/pip-* ${BUILD_PATH}/python/lib/tcl* ${BUILD_PATH}/python/lib/tk* \
        ${BUILD_PATH}/python/lib/itcl* ${BUILD_PATH}/python/lib/thread* ${BUILD_PATH}/python/share/terminfo \
        ${BUILD_PATH}/python/bin/idle3* ${BUILD_PATH}/python/bin/pip*
    rm -f ${lib}/lib-dynload/_tkinter*
    find ${lib}/site-packages -name '*.so' -exec strip --strip-unneeded {} +
}

# Gathers its web interface's files as its web server serves them (static/), and leaves out what only builds, tests or
# packages it.
function finish_linkding() {
    local data

    cd ${BUILD_PATH}/linkding
    # (its settings read a secret key from data/, which the NAS keeps elsewhere: a scratch one here)
    data="$(mktemp -d)"
    ln -s "${data}" data
    DJANGO_SETTINGS_MODULE=bookmarks.settings.prod ${BUILD_PATH}/python/bin/python3 manage.py collectstatic --noinput \
        > /dev/null
    rm -f data
    rm -rf "${data}"

    rm -rf node_modules .github docs docker scripts bookmarks/frontend bookmarks/styles bookmarks/tests \
        bookmarks/e2e package.json package-lock.json pyproject.toml uv.lock pytest.ini Makefile docker-compose.yml \
        install-linkding.sh bootstrap.sh supervisord-all.conf supervisord-tasks.conf .dockerignore .gitignore \
        .prettierrc .env.sample CHANGELOG.md SECURITY.md

    # Its web server's settings, without its Docker image's parts (see above)
    sed -i -e '/^uid = /d' -e '/^gid = /d' -e '/^pidfile = /d' -e '/^stats = /d' uwsgi.ini

    if grep -qE '^(uid|gid|pidfile|stats) = ' uwsgi.ini; then
        echo 'uwsgi.ini still has its Docker image'"'"'s parts'

        exit 1
    fi

    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${BUILD_PATH}/python/bin/python3 -m compileall -q . ${BUILD_PATH}/python/lib/python3.13 > /dev/null || true
}

# Checks that every compiled part runs with the NAS's glibc.
function check_glibc() {
    local found=0
    local file version

    while read -r file; do
        head -c 4 "${file}" | grep -q ELF || continue

        for version in $(objdump -T "${file}" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u); do
            if [ "${version#GLIBC_2.}" -gt "${NAS_GLIBC#2.}" ]; then
                echo "${file} needs ${version}"
                found=1
            fi
        done
    done < <(find ${BUILD_PATH}/python -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${NAS_GLIBC})"

        exit 1
    fi
}

# Builds the run-as helper.
function build_runas() {
    cd ${BUILD_PATH}
    cat > linkding_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: linkding_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("linkding_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("linkding_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o linkding_runas linkding_runas.c
}

# Starts the build in a scratch folder (its database made, as on the NAS), and checks that its login page answers.
function check() {
    local data pid attempt page

    data="$(mktemp -d)"
    cd ${OUTPUT_PATH}/linkding
    ln -s "${data}" data
    export DJANGO_SETTINGS_MODULE=bookmarks.settings.prod
    ${OUTPUT_PATH}/python/bin/python3 manage.py generate_secret_key
    ${OUTPUT_PATH}/python/bin/python3 manage.py migrate --noinput > /dev/null
    LD_LIBRARY_PATH=${OUTPUT_PATH}/python/lib ${OUTPUT_PATH}/python/bin/uwsgi --http 127.0.0.1:9099 uwsgi.ini \
        > ${BUILD_PATH}/uwsgi.log 2>&1 &
    pid=$!
    page=''

    for attempt in $(seq 1 30); do
        page="$(curl -s -m 2 http://127.0.0.1:9099/login/ || true)"
        [ -n "${page}" ] && break
        sleep 1
    done

    kill ${pid}
    wait ${pid} || true
    rm -f data
    rm -rf "${data}"
    unset DJANGO_SETTINGS_MODULE

    if ! echo "${page}" | grep -qi 'linkding'; then
        cat ${BUILD_PATH}/uwsgi.log

        exit 1
    fi
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_tools
    build_source
    build_python
    finish_linkding
    check_glibc
    build_runas

    # Nothing may differ only in case (see build_python)
    if [ -n "$(find ${BUILD_PATH}/python ${BUILD_PATH}/linkding | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${BUILD_PATH}/python ${BUILD_PATH}/linkding | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    cp -a ${BUILD_PATH}/python ${BUILD_PATH}/linkding ${BUILD_PATH}/linkding_runas ${OUTPUT_PATH}/
    check
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/*

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/linkding/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
