#!/bin/bash

# Prepares RetroAssembly for the NAS (the Intel models): built from its source - GitHub's archive of its tag, pinned
# here (it publishes no other release) - as its own Docker image builds it: its packages from its lock file with pnpm,
# its web interface and server built, then only the packages the server needs (in npm's flat layout: no links, which a
# Windows drive holding the repository can't always keep), with its own Node.js runtime (the official build: it needs
# Node.js 26). Two changes to its source, both checked:
#  - sign-ups: RetroAssembly always lets anyone who can reach it make an account; the app only allows it when it says
#    so (RETROASSEMBLY_NAS_SIGNUPS=on: its first start, to make the admin account, or the page's setting)
#  - its address: it always listens on every one; the app chooses (RETROASSEMBLY_NAS_HOST: the NAS itself only, behind
#    the Nginx app)
# Plus fully static builds of:
#  - sqlite3:          SQLite's shell, for safe backups of RetroAssembly's database while it runs
#  - retroassembly_runas: switches to RetroAssembly's own user (the NAS has no su or similar) before running it
# And the sample games the app adds to the admin's library (in samples/, listed in samples.tsv): homebrew games whose
# authors publish them under open licenses, each from its author's release (checksums pinned here).

set -e
set -o pipefail
set -x

VERSION=7.261011.1345
# GitHub's archive of its tag
RETROASSEMBLY_SHA256=35475be5febdc74b9c1d6afa076284691c9a8a84da5ffe32a33ad7e395cda9ce
NODE_VERSION=26.13.1
# As Node.js's SHASUMS256.txt (signed by its releasers) publishes it
NODE_SHA256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
SQLITE_VERSION=3540100
SQLITE_YEAR=2026
# SQLite publishes SHA3-256 hashes: 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30 - checked to match
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
# The sample games: <file> | <platform> | <name> | <author> | <license> | <its project's page> | <download> |
# <sha256> - µCity's checksum is
# its release's own; the others were taken from their releases (which publish none)
SAMPLES='thwaite.nes | nes | Thwaite | Damian Yerrick | GPL-3.0 | github.com/pinobatch/thwaite-nes | https://github.com/pinobatch/thwaite-nes/releases/download/v0.04/thwaite.nes | a2df24d9c9f72e56c2fdc4c703becc47a5700ad0158da8208247635ebeb3779c
croom.nes | nes | Concentration Room | Damian Yerrick | GPL-3.0 | github.com/pinobatch/croom-nes | https://github.com/pinobatch/croom-nes/releases/download/v0.02a/croom.nes | 2ce17df1ad66a8a0533c0a8739f5b5ebe275c264924bbe350c42c5ac0394f20e
dabg.nes | nes | Double Action Blaster Guys | NovaSquirrel | Zlib | github.com/NovaSquirrel/DABG | https://github.com/NovaSquirrel/DABG/releases/download/v2/dabg.nes | eca79b9d0b546e96c1bc73099e239539fb9c7773ff10a431bb3a9cd6763208ca
libbet.gb | gb | Libbet and the Magic Floor | Damian Yerrick | Zlib | github.com/pinobatch/libbet | https://github.com/pinobatch/libbet/releases/download/v0.08/libbet.gb | 3607412031c8287cf878299ce96e581e85b852dde703806343b95576fa3ff1a9
ucity.gbc | gbc | µCity | Antonio Niño Díaz | GPL-3.0-or-later (graphics and music: CC-BY-SA-4.0) | github.com/AntonioND/ucity | https://github.com/AntonioND/ucity/releases/download/v1.3/ucity.gbc | 9422ee2ca7b7ea1d46b58b2a429fff3f354dfd3e732dee1e7ae6220f148ce6e0'
# The newest glibc / libstdc++ symbol versions the NAS has (OS5: glibc 2.31, GLIBCXX 3.4.28)
NAS_GLIBC=2.31
NAS_GLIBCXX=3.4.28

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/retroassembly/${VERSION}/amd64

# Downloads a file into ${BUILD_PATH} and checks it against its SHA256 (static/fetch.sh: a kept copy, its site, then
# the source mirror).
#
# $1 url    Its address
# $2 file   Where it goes
# $3 sha256 Its SHA256
function fetch() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "$1" "$2" "$3"
}

# Whether version $1 is newer than version $2.
#
# $1 version The one
# $2 other   The other
function newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Checks that every compiled module in a folder runs with the NAS's own libraries (modules for other systems or
# processors, which some packages include, are removed).
#
# $1 folder The folder
function check_modules() {
    local module glibc glibcxx

    while read -r module; do
        if [ "$(head -c 4 "${module}" | tail -c 3)" != ELF ] || ! objdump -f "${module}" | grep -q 'x86-64'; then
            rm -f "${module}"
            continue
        fi

        # (a module may use no C++ at all: grep finding nothing isn't an error)
        glibc="$(objdump -T "${module}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -V \
            | tail -n 1)"
        glibcxx="$(objdump -T "${module}" | { grep -o 'GLIBCXX_[0-9.]*' || true; } | sed 's/GLIBCXX_//' | sort -V \
            | tail -n 1)"
        echo "${module}: GLIBC ${glibc:-none}, GLIBCXX ${glibcxx:-none}"

        if { [ -n "${glibc}" ] && newer "${glibc}" "${NAS_GLIBC}"; } \
            || { [ -n "${glibcxx}" ] && newer "${glibcxx}" "${NAS_GLIBCXX}"; }; then
            echo "${module} needs newer libraries than the NAS has"

            exit 1
        fi
    done < <(find "$1" -name '*.node')
}

# Puts Node.js into ${BUILD_PATH}/node, in the PATH.
function build_node() {
    fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" node.tar.xz ${NODE_SHA256}
    tar -xJf node.tar.xz
    mv node-v${NODE_VERSION}-linux-x64 node
    export PATH="${BUILD_PATH}/node/bin:${PATH}"
}

# Puts the pnpm RetroAssembly's lock file is for (its package.json's packageManager) in the PATH - npm checks it
# against the registry's integrity.
#
# $1 folder Its source
function build_pnpm() {
    local version

    version="$(sed -n 's/.*"packageManager": "pnpm@\([0-9.]*\)".*/\1/p' "$1/package.json")"
    [ -n "${version}" ]
    npm install --global --no-audit --no-fund "pnpm@${version}"
    pnpm --version | grep -qx "${version}"
}

# Makes the app's two changes to RetroAssembly's source (see above), checking that each was made.
#
# $1 folder Its source
function patch_source() {
    python3 - "$1" <<'PY'
import sys

source = sys.argv[1]


def patch(path, old, new):
    """
    Replaces a part of a source file, which must be there exactly once.

    :param str path: The file, in the source
    :param str old:  What it has
    :param str new:  What it gets instead
    """
    path = f"{source}/{path}"

    with open(path, encoding="utf-8") as file:
        text = file.read()

    if text.count(old) != 1:
        sys.exit(f"{path}: the part to change isn't there (once)")

    with open(path, "w", encoding="utf-8") as file:
        file.write(text.replace(old, new))


patch(
    "src/api/routes/auth.ts",
    "throw new HTTPException(403, { message: 'Password registration is disabled' })\n      }\n",
    "throw new HTTPException(403, { message: 'Password registration is disabled' })\n      }\n"
    "      if (process.env.RETROASSEMBLY_NAS_SIGNUPS !== 'on') {\n"
    "        throw new HTTPException(403, { message: 'Sign-ups are off: ask the admin for an account' })\n"
    "      }\n",
)
patch(
    "scripts/serve.ts",
    "const hostname = '0.0.0.0'",
    "const hostname = process.env.RETROASSEMBLY_NAS_HOST || '0.0.0.0'",
)
PY
}

# Builds RetroAssembly into ${BUILD_PATH}/retroassembly: its server and web interface, and the packages its server
# needs - as its Docker image is laid out.
function build_retroassembly() {
    local source=${BUILD_PATH}/source
    local production=${BUILD_PATH}/production
    local app=${BUILD_PATH}/retroassembly

    fetch "https://github.com/arianrhodsandlot/retroassembly/archive/refs/tags/v${VERSION}.tar.gz" \
        retroassembly.tar.gz ${RETROASSEMBLY_SHA256}
    mkdir -p ${source}
    tar -xzf retroassembly.tar.gz -C ${source} --strip-components=1
    build_pnpm ${source}
    patch_source ${source}

    # (its build reports its version from this; no analytics project is set, so its browser code sends none)
    cd ${source}
    SKIP_INSTALL_SIMPLE_GIT_HOOKS=true pnpm install --frozen-lockfile
    RETROASSEMBLY_BUILD_TIME_VITE_VERSION="v${VERSION}" node --run=build
    grep -q 'RETROASSEMBLY_NAS_HOST' dist/server/serve.js

    # Only the packages its server needs (with their changes, as its lock file has them)
    mkdir -p ${production}
    cp -a package.json pnpm-lock.yaml pnpm-workspace.yaml patches ${production}/
    cd ${production}
    SKIP_INSTALL_SIMPLE_GIT_HOOKS=true pnpm install --prod --frozen-lockfile --config.node-linker=hoisted
    rm -rf node_modules/.bin node_modules/.cache node_modules/.pnpm
    # better-sqlite3's ready-built module needs a newer glibc than the NAS's: compiled here instead, on its Debian
    # version (with node-gyp, which npm brings, and the headers of the Node.js it runs on - in its download)
    (
        cd node_modules/better-sqlite3
        [ -f binding.gyp ]
        rm -rf prebuilds build
        node "${BUILD_PATH}/node/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js" rebuild --release \
            --nodedir="${BUILD_PATH}/node" -j "$(nproc)"
        rm -rf build/Release/obj.target build/Release/.deps build/deps
    )
    check_modules node_modules
    [ -f node_modules/better-sqlite3/build/Release/better_sqlite3.node ]

    mkdir -p ${app}/src
    cp -a ${source}/package.json ${source}/dist ${app}/
    cp -a ${source}/src/databases ${app}/src/
    cp -a ${production}/node_modules ${app}/

    # Nothing may be a link, or differ from something else only in case (see above)
    if [ -n "$(find ${app} -type l)" ]; then
        find ${app} -type l | head
        echo 'RetroAssembly has links in it'

        exit 1
    fi

    if [ -n "$(find ${app} | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ]; then
        find ${app} | tr '[:upper:]' '[:lower:]' | sort | uniq -d | head
        echo 'These paths differ only in case'

        exit 1
    fi
}

# Downloads the sample games into ${BUILD_PATH}/samples, with their list (samples.tsv: file, platform, name, author,
# license, project).
function build_samples() {
    local file platform name author license project url sha256

    mkdir -p ${BUILD_PATH}/samples
    : > ${BUILD_PATH}/samples/samples.tsv

    # (its fields are separated by " | ", so that its addresses stand on their own)
    printf '%s\n' "${SAMPLES}" | sed 's/ | /\t/g' \
        | while IFS="$(printf '\t')" read -r file platform name author license project url sha256; do
            fetch "${url}" "samples/${file}" "${sha256}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${file}" "${platform}" "${name}" "${author}" "${license}" \
                "${project}" >> ${BUILD_PATH}/samples/samples.tsv
        done
}

# Builds SQLite's shell (as static/homebox does).
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
    gcc -O2 -static -s -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 shell.c sqlite3.c -lm \
        -o ${BUILD_PATH}/sqlite3
}

# Builds the run-as helper.
function build_runas() {
    cd ${BUILD_PATH}
    cat > retroassembly_runas.c <<'C'
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Run by root: switches to the given user and group (dropping all others), then runs the program
int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "Usage: retroassembly_runas <uid> <gid> <program> [arguments...]\n");
		return 2;
	}
	uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
	gid_t gid = (gid_t)strtoul(argv[2], NULL, 10);
	if (setgroups(0, NULL) != 0 || setgid(gid) != 0 || setuid(uid) != 0) {
		perror("retroassembly_runas: could not switch user");
		return 1;
	}
	execv(argv[3], &argv[3]);
	perror("retroassembly_runas: could not run the program");
	return 127;
}
C
    gcc -O2 -static -s -o retroassembly_runas retroassembly_runas.c
}

# Starts the build in a scratch folder (on the NAS's address only, sign-ups as given) and checks its answer to a
# sign-up; stops it again.
#
# $1 signups on or off
# $2 code    The HTTP status expected for a sign-up (200 or 403)
function check_signup() {
    local data=${BUILD_PATH}/check
    local pid code attempt

    mkdir -p ${data}/storage
    cd ${OUTPUT_PATH}/retroassembly
    RETROASSEMBLY_NAS_HOST=127.0.0.1 RETROASSEMBLY_NAS_SIGNUPS="$1" RETROASSEMBLY_RUN_TIME_PORT=8098 \
        RETROASSEMBLY_RUN_TIME_DATA_DIRECTORY=${data} RETROASSEMBLY_RUN_TIME_STORAGE_DIRECTORY=${data}/storage \
        ${OUTPUT_PATH}/node --no-experimental-webstorage dist/server/serve.js > ${data}.log 2>&1 &
    pid=$!

    for attempt in $(seq 1 60); do
        curl -s -m 2 -o /dev/null http://127.0.0.1:8098/login && break
        sleep 1
    done

    code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' -d username=check -d password=check-password \
        http://127.0.0.1:8098/api/v1/auth/register)"
    kill ${pid}
    wait ${pid} || true

    if [ "${code}" != "$2" ]; then
        cat ${data}.log
        echo "A sign-up with sign-ups $1 was answered ${code}, not $2"

        exit 1
    fi

    rm -rf ${data}
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    build_node
    build_retroassembly
    build_samples
    build_sqlite
    build_runas

    rm -rf ${OUTPUT_PATH}
    mkdir -p ${OUTPUT_PATH}
    # Only Node.js itself: RetroAssembly's packages are installed (no npm or pnpm needed on the NAS)
    cp ${BUILD_PATH}/node/bin/node ${BUILD_PATH}/sqlite3 ${BUILD_PATH}/retroassembly_runas ${OUTPUT_PATH}/
    cp ${BUILD_PATH}/node/LICENSE ${OUTPUT_PATH}/node-LICENSE
    cp -a ${BUILD_PATH}/retroassembly ${BUILD_PATH}/samples ${OUTPUT_PATH}/

    # Its changes at work: sign-ups refused unless allowed (and a sign-up then works: its database made, its account)
    check_signup off 403
    check_signup on 200
    ${OUTPUT_PATH}/node --version
    [ "$(echo 'SELECT 1;' | ${OUTPUT_PATH}/sqlite3 :memory:)" = 1 ]
    du -sh ${OUTPUT_PATH} ${OUTPUT_PATH}/retroassembly/node_modules ${OUTPUT_PATH}/samples

    # Create a latest release file for ease of use in packages
    LATEST_PATH=/data/packages/static/retroassembly/latest
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
