#!/bin/bash

# Prepares changedetection.io (watches web pages for changes) for the NAS's Intel models: its own Python (a portable,
# relocatable build, python-build-standalone's) with changedetection.io and its packages installed into it (from
# static/changedetection/requirements.txt: each version with its files' checksums, wheels checked against the NAS's
# glibc), plus:
#  - Patchright in place of Playwright: changedetection.io drives a browser (when one is set up - the Browser recipe,
#    or one on another machine) through Playwright; Patchright is a drop-in replacement that hides what gives automated
#    browsers away (it doesn't enable DevTools' Runtime and Console domains, which sites can detect). Its imports in
#    changedetection.io are rewritten to Patchright's, and checked
#  - changedetection_runas: switches to changedetection.io's own user (the NAS has no su or similar) before running it
#
# Only for the Intel models: several of its packages (lxml, gevent, orjson, cryptography, numpy, tokenizers...) and
# Patchright's driver have no 32-bit ARM builds. The build is checked by starting changedetection.io with a password,
# and having it notice a change on a page served locally - through its API, as the app's tests do.

set -e
set -o pipefail
set -x

VERSION=0.70.3
# changedetection.io's own wheel, as PyPI publishes it
CHANGEDETECTION_WHEEL_SHA256=3eba2a313eb8ebe2713058707008ddfee10808e20acd47d21ae242bd05950d41
# Patchright (Python), matched to the Chrome version the Browser recipe runs (see recipes/changedetection-browser)
PATCHRIGHT_VERSION=1.64.4
PYTHON_VERSION=3.14.10
PYTHON_RELEASE=20261026
PYTHON_SHA256=4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed
UV_VERSION=0.13.6
UV_SHA256=5d61f26b6c7213779eda90edc6971ea6b0b796bfb8d49a574c8ad69b59838548
# The newest glibc symbol version the NAS has (OS5's Intel models: glibc 2.31)
NAS_GLIBC=2.31
# The packages PyPI only has as source (pure Python, or websockets - pinned old by pyppeteer-ng, without a Python 3.14
# wheel): built here
SOURCE_ONLY='feedgen jstyleson websockets'

BUILD_PATH=/build
# Built here, then copied to OUTPUT once checked (build_static.sh takes an output folder that isn't empty as built)
STAGE=${BUILD_PATH}/out
OUTPUT=/data/packages/static/changedetection/${VERSION}/amd64
# changedetection.io's packages, each version with the checksums of its files: written by the first build, then reused
# (so that rebuilds install exactly the same packages) - delete it to take newer ones
LOCK=/data/static/changedetection/requirements.txt
SITE=${STAGE}/python/lib/python3.14/site-packages

# Downloads a file into the current folder and checks it against its SHA256.
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# The options that let uv build only the source-only packages (each as --no-binary <name>).
#
# Prints them
function source_only_options() {
    local package

    for package in ${SOURCE_ONLY}; do
        printf -- '--no-binary %s ' "${package}"
    done
}

# Downloads Python and uv, unpacks Python into ${STAGE}/python and puts uv on the PATH.
function prepare() {
    cd ${BUILD_PATH}
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
        python.tar.gz ${PYTHON_SHA256}
    fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
        uv.tar.gz ${UV_SHA256}
    tar -xzf uv.tar.gz
    export PATH="${BUILD_PATH}/uv-x86_64-unknown-linux-musl:${PATH}"

    mkdir -p ${STAGE}
    cd ${STAGE}
    tar -xzf ${BUILD_PATH}/python.tar.gz
}

# Installs changedetection.io and Patchright with their packages into the Python (from the lock, written first if
# missing), rewrites changedetection.io's Playwright imports to Patchright's, and trims what a server doesn't need.
function build_python() {
    local lib=${STAGE}/python/lib/python3.14
    local python=${STAGE}/python/bin/python3

    # The lock, written once (see LOCK): wheels for the NAS's glibc, apart from the source-only packages
    if [ ! -f ${LOCK} ]; then
        printf 'changedetection.io==%s\npatchright==%s\n' "${VERSION}" "${PATCHRIGHT_VERSION}" > ${BUILD_PATH}/requirements.in
        uv pip compile --quiet --python ${python} --python-platform x86_64-manylinux_${NAS_GLIBC/./_} \
            --only-binary :all: $(source_only_options) --generate-hashes --no-header ${BUILD_PATH}/requirements.in \
            -o ${LOCK}
    fi

    # The lock must hold changedetection.io's own published checksum
    grep -q "${CHANGEDETECTION_WHEEL_SHA256}" ${LOCK}

    uv pip install --python ${python} --break-system-packages --python-platform x86_64-manylinux_${NAS_GLIBC/./_} \
        --only-binary :all: $(source_only_options) --require-hashes -r ${LOCK}
    # (the scripts uv writes call this Python by its build path: the app runs changedetection.io's main() itself)
    rm -f ${STAGE}/python/bin/changedetection.io

    # Patchright in place of Playwright: the same API, under its own name
    grep -rlE 'from playwright\.|import playwright\.|playwright\._impl' ${SITE}/changedetectionio --include='*.py' \
        | xargs sed -i -E 's/from playwright\./from patchright./g; s/import playwright\._impl/import patchright._impl/g;
            s/([^a-z_.])playwright\._impl/\1patchright._impl/g'

    if grep -rnE '(from|import) playwright\b|[^a-z_.]playwright\._impl' ${SITE}/changedetectionio --include='*.py' \
        | grep -v '/tests/'; then
        echo 'Playwright is still imported somewhere (above): Patchright replaces it'

        exit 1
    fi

    # Not needed by a server: IDLE and Tk (a desktop GUI), the tests, pip (nothing is installed into it on the NAS), the
    # terminal database - whose folders differ only in case, which a Windows drive holding the repository can't store;
    # changedetection.io's own tests; Selenium's driver managers for other systems (and Selenium's only used without a
    # browser set up: it then finds no driver anyway); LiteLLM's web interface (for its proxy server, not used here)
    rm -rf ${lib}/idlelib ${lib}/tkinter ${lib}/turtledemo ${lib}/test ${lib}/ensurepip ${SITE}/pip ${SITE}/pip-* \
        ${STAGE}/python/lib/tcl* ${STAGE}/python/lib/tk* ${STAGE}/python/lib/libtcl* ${STAGE}/python/lib/libtk* \
        ${STAGE}/python/lib/itcl* ${STAGE}/python/lib/thread* ${STAGE}/python/share/terminfo \
        ${STAGE}/python/bin/idle3* ${STAGE}/python/bin/pip* \
        ${SITE}/changedetectionio/tests \
        ${SITE}/selenium/webdriver/common/macos ${SITE}/selenium/webdriver/common/windows \
        ${SITE}/selenium/webdriver/common/linux-arm64 \
        ${SITE}/litellm/proxy/_experimental/out
    rm -f ${lib}/lib-dynload/_tkinter*
    # Patchright's own Node.js (its driver) comes with its debugging symbols
    strip ${SITE}/patchright/driver/node

    printf '%s\n' "${VERSION}" > ${STAGE}/version

    # Its compiled bytecode, made now for a faster start (the app's folder isn't writable by its user)
    ${python} -m compileall -q ${lib} > /dev/null || true
}

# Builds the run-as helper.
function build_runas() {
    cd ${BUILD_PATH}
    cat > changedetection_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: changedetection_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("changedetection_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("changedetection_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o ${STAGE}/changedetection_runas changedetection_runas.c
    rm changedetection_runas.c
}

# Checks that nothing needs a newer glibc than the NAS's.
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
    done < <(find ${STAGE} -type f \( -name '*.so*' -o -perm -u+x \))

    if [ ${found} = 1 ]; then
        echo "Something needs a newer glibc than the NAS's (${NAS_GLIBC})"

        exit 1
    fi
}

# Checks the build: the programs run (Patchright's driver too), changedetection.io's browser fetcher loads with
# Patchright, and changedetection.io - started in a scratch folder, with a password - refuses its pages without logging
# in, and notices a change on a page served locally, through its API.
function check() {
    local data=${BUILD_PATH}/check
    local python=${STAGE}/python/bin/python3
    local pid server attempt result key uuid count

    ${python} -c 'import sys, ssl; print(sys.version.split()[0], ssl.OPENSSL_VERSION)'
    ${python} -c 'import changedetectionio; print("changedetection.io", changedetectionio.__version__)' \
        | grep -qx "changedetection.io ${VERSION}"
    ${python} -m patchright --version
    PLAYWRIGHT_DRIVER_URL=ws://127.0.0.1:1 ${python} -c 'import patchright.async_api, patchright._impl._errors
from changedetectionio.content_fetchers import html_webdriver
assert html_webdriver.__module__.endswith(".playwright"), html_webdriver.__module__
print("browser fetcher:", html_webdriver.__module__)'
    # (no arguments: it says how to use it, and fails - showing that it runs)
    result="$(${STAGE}/changedetection_runas 2>&1 || true)"
    echo "${result}" | grep -q 'Usage: changedetection_runas'

    # A page to watch, served locally
    mkdir -p ${data}/www ${data}/datastore
    printf '<html><body><p>Price: 10</p></body></html>\n' > ${data}/www/page.html
    ( cd ${data}/www && exec ${python} -m http.server 8998 --bind 127.0.0.1 ) > ${data}/http.log 2>&1 &
    server=$!

    # Its password, as the app sets it: base64 of a 32-byte salt and the PBKDF2-SHA256 key (100,000 rounds)
    export SALTED_PASS="$(${python} -c 'import base64, hashlib, os
salt = os.urandom(32)
print(base64.b64encode(salt + hashlib.pbkdf2_hmac("sha256", b"Check.Password-1", salt, 100000)).decode())')"
    ( cd ${data} && LOGGER_LEVEL=WARNING ALLOW_IANA_RESTRICTED_ADDRESSES=true MINIMUM_SECONDS_RECHECK_TIME=1 \
        exec ${python} -c 'import changedetectionio; changedetectionio.main()' -d ${data}/datastore -h 127.0.0.1 \
        -p 5099 ) > ${data}/changedetection.log 2>&1 &
    pid=$!
    unset SALTED_PASS

    for attempt in $(seq 1 90); do
        [ -f ${data}/datastore/changedetection.json ] && curl -s -o /dev/null http://127.0.0.1:5099/ && break
        sleep 1
    done

    result="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1:5099/)"
    key="$(${python} -c 'import json, sys
print(json.load(open(sys.argv[1]))["settings"]["application"]["api_access_token"])' \
        ${data}/datastore/changedetection.json)"
    uuid="$(curl -s -H "x-api-key: ${key}" -H 'Content-Type: application/json' \
        -d '{"url": "http://127.0.0.1:8998/page.html", "time_between_check": {"seconds": 5}}' \
        http://127.0.0.1:5099/api/v1/watch | ${python} -c 'import json, sys; print(json.load(sys.stdin)["uuid"])')"
    count=0

    # Its first check, then a change and another check: two versions in its history
    for attempt in $(seq 1 120); do
        count="$(curl -s -H "x-api-key: ${key}" http://127.0.0.1:5099/api/v1/watch/${uuid}/history \
            | ${python} -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"

        if [ "${count}" = 1 ] && grep -q 'Price: 10' ${data}/www/page.html; then
            printf '<html><body><p>Price: 12</p></body></html>\n' > ${data}/www/page.html
            curl -s -o /dev/null -H "x-api-key: ${key}" "http://127.0.0.1:5099/api/v1/watch/${uuid}?recheck=1"
        fi

        [ "${count}" -ge 2 ] && break
        sleep 1
    done

    kill ${pid} ${server} 2>/dev/null || true
    wait ${pid} ${server} 2>/dev/null || true

    # (without logging in: sent to its login page)
    if ! echo "${result}" | grep -q '^30[1-8] .*login' || [ "${count}" -lt 2 ]; then
        echo "changedetection.io's check failed: '${result}' without logging in, ${count} versions of the page"
        cat ${data}/changedetection.log

        exit 1
    fi
}

function run() {
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    prepare
    build_python
    build_runas
    check_glibc
    check

    # Nothing may differ only in case (see build_python)
    if [ -n "$(find ${STAGE} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${STAGE} | tr '[:upper:]' '[:lower:]' | sort | uniq -d
        echo 'These paths differ only in case'

        exit 1
    fi

    rm -rf ${OUTPUT}
    mkdir -p ${OUTPUT}
    cp -a ${STAGE}/. ${OUTPUT}/
    du -sh ${OUTPUT}

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/changedetection/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages /data/static/changedetection/requirements.txt
}

run
