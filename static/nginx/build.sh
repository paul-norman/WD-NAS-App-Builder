#!/bin/bash

# Builds Nginx as a fully static binary, with OpenSSL, PCRE2, zlib and Brotli compression (Google's ngx_brotli) built
# in - for the Intel models and the ARM ones. All paths are relative to the prefix given at runtime (nginx -p <folder>),
# so the app keeps its configuration, logs and temporary files together.

# The ARM models' build is made on this (Intel) machine: cross-compiled with Zig for their ARMv7 processors (hard-float,
# musl), its libraries built first, and checked with QEMU's emulator - serving pages over HTTPS. Nginx's configure runs
# small test programs to learn about the system, so the compiler's wrapper turns those into scripts running them with
# QEMU.

set -e
set -o pipefail
set -x

VERSION=1.30.6
OPENSSL_VERSION=3.5.9
PCRE2_VERSION=10.49
ZLIB_VERSION=1.3.2
BROTLI_VERSION=1.2.1
# ngx_brotli has no releases: pinned to its latest commit
NGX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53
# Checked against nginx's signature (Sergey Kandaurov's key, as nginx.org publishes it), OpenSSL's published SHA256,
# PCRE2's and zlib's signatures (Nicholas Wilson's, Mark Adler's keys); Brotli's are GitHub's archives as first
# downloaded (nothing published to check them against)
NGINX_SHA256=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
PCRE2_SHA256=929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
NGX_BROTLI_SHA256=1d21be34f3b7b6d05a8142945e59b3a47665edcdfe0f3ee3d3dbef121f90c08c
BROTLI_SHA256=98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f
# The architectures built (each into packages/static/nginx/<version>/<arch>)
ARCHES='amd64 armhf'

BUILD_PATH=/build
TOOLS_PATH=/build/tools
ARM_HOST=arm-linux-musleabihf
OUTPUT_ROOT=/data/packages/static/nginx/${VERSION}

# Nginx's configure options, the same for both architectures (apart from its libraries). Relative paths are relative to
# the prefix (overridden at runtime with -p)
NGINX_OPTIONS=(
    --prefix=/usr/local/nginx
    --conf-path=conf/nginx.conf
    --error-log-path=logs/error.log
    --http-log-path=logs/access.log
    --pid-path=logs/nginx.pid
    --lock-path=logs/nginx.lock
    --http-client-body-temp-path=temp/client_body
    --http-proxy-temp-path=temp/proxy
    --http-fastcgi-temp-path=temp/fastcgi
    --http-uwsgi-temp-path=temp/uwsgi
    --http-scgi-temp-path=temp/scgi
    --with-threads
    --with-file-aio
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_v3_module
    --with-http_realip_module
    --with-http_stub_status_module
    --with-http_gzip_static_module
    --with-http_gunzip_module
    --with-http_auth_request_module
    --with-http_sub_module
    --with-http_secure_link_module
    --with-stream
    --with-stream_ssl_module
    --with-stream_ssl_preread_module
    --with-stream_realip_module
    --with-pcre-jit
)

function download() {
    cd ${BUILD_PATH}
    sh /data/static/fetch.sh "https://nginx.org/download/nginx-${VERSION}.tar.gz" \
        nginx-${VERSION}.tar.gz "${NGINX_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        openssl-${OPENSSL_VERSION}.tar.gz "${OPENSSL_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" \
        pcre2-${PCRE2_VERSION}.tar.gz "${PCRE2_SHA256}"
    sh /data/static/fetch.sh \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        zlib-${ZLIB_VERSION}.tar.gz "${ZLIB_SHA256}"
    sh /data/static/fetch.sh "https://github.com/google/ngx_brotli/archive/${NGX_BROTLI_COMMIT}.tar.gz" \
        ngx_brotli.tar.gz "${NGX_BROTLI_SHA256}"
    sh /data/static/fetch.sh "https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz" \
        brotli.tar.gz "${BROTLI_SHA256}"

    for archive in *.tar.gz; do
        tar -xzf "${archive}"
    done
}

function build_brotli() {
    # ngx_brotli expects the Brotli library's source in deps/brotli (normally a git submodule - here the latest release
    # instead), built as static libraries in deps/brotli/out
    cd ${BUILD_PATH}
    mv ngx_brotli-${NGX_BROTLI_COMMIT} ngx_brotli
    rm -rf ngx_brotli/deps/brotli
    mv brotli-${BROTLI_VERSION} ngx_brotli/deps/brotli
    cmake -S ngx_brotli/deps/brotli -B ngx_brotli/deps/brotli/out -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DBROTLI_DISABLE_TESTS=ON -DCMAKE_C_FLAGS='-O2 -fPIC'
    cmake --build ngx_brotli/deps/brotli/out -j "$(nproc)" --target brotlienc brotlicommon
}

function build_nginx() {
    cd ${BUILD_PATH}/nginx-${VERSION}

    ./configure "${NGINX_OPTIONS[@]}" \
        --add-module=${BUILD_PATH}/ngx_brotli \
        --with-pcre=${BUILD_PATH}/pcre2-${PCRE2_VERSION} \
        --with-zlib=${BUILD_PATH}/zlib-${ZLIB_VERSION} \
        --with-openssl=${BUILD_PATH}/openssl-${OPENSSL_VERSION} \
        --with-openssl-opt='no-shared no-tests no-docs' \
        --with-cc-opt='-static -O2' \
        --with-ld-opt='-static'
    make -j "$(nproc)"
    strip objs/nginx
}

# Writes the ARM compiler's commands (Zig's, for the ARM models' processors): arm-cc, arm-ar and arm-ranlib. arm-cc
# turns a program built as autotest (Nginx's configure's tests, which it runs) into a script running it with QEMU.
function make_tools() {
    mkdir -p ${TOOLS_PATH}
    {
        echo '#!/bin/sh'
        echo "out=''"
        echo "previous=''"
        echo 'for arg in "$@"; do'
        echo '    [ "${previous}" = -o ] && out="${arg}"'
        echo '    previous="${arg}"'
        echo 'done'
        echo "zig cc -target ${ARM_HOST} -mcpu=cortex_a9 \"\$@\" || exit \$?"
        echo 'case "${out}" in'
        echo '    autotest|*/autotest)'
        echo '        program="$(cd "$(dirname "${out}")" && pwd)/autotest.arm"'
        echo '        mv "${out}" "${program}"'
        echo '        printf "#!/bin/sh\\nexec qemu-arm -cpu cortex-a9 %s \"\$@\"\\n" "${program}" > "${out}"'
        echo '        chmod 755 "${out}"'
        echo '        ;;'
        echo 'esac'
    } > ${TOOLS_PATH}/arm-cc
    printf '#!/bin/sh\nexec zig ar "$@"\n' > ${TOOLS_PATH}/arm-ar
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ${TOOLS_PATH}/arm-ranlib
    chmod 755 ${TOOLS_PATH}/arm-cc ${TOOLS_PATH}/arm-ar ${TOOLS_PATH}/arm-ranlib
}

# Builds zlib, PCRE2 (with its JIT) and OpenSSL for the ARM models, static, into ${BUILD_PATH}/armhf/deps - and
# ngx_brotli's own copy of the Brotli library, in ${BUILD_PATH}/armhf/ngx_brotli.
function build_arm_libraries() {
    local deps=${BUILD_PATH}/armhf/deps
    local tools="CC=${TOOLS_PATH}/arm-cc AR=${TOOLS_PATH}/arm-ar RANLIB=${TOOLS_PATH}/arm-ranlib"

    mkdir -p ${BUILD_PATH}/armhf
    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/zlib-${ZLIB_VERSION}.tar.gz
    cd zlib-${ZLIB_VERSION}
    env ${tools} CFLAGS=-O2 ./configure --static --prefix=${deps}
    make -j "$(nproc)" libz.a
    make install

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/pcre2-${PCRE2_VERSION}.tar.gz
    cd pcre2-${PCRE2_VERSION}
    env ${tools} CFLAGS=-O2 ./configure --build=x86_64-linux-musl --host=${ARM_HOST} --prefix=${deps} \
        --disable-shared --enable-static --enable-jit
    make -j "$(nproc)"
    make install

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/openssl-${OPENSSL_VERSION}.tar.gz
    cd openssl-${OPENSSL_VERSION}
    # Only the libraries (no programs, tests or documents), with no loadable modules or engines
    ./Configure linux-armv4 --prefix=${deps} --libdir=lib --openssldir=/etc/ssl -O2 \
        no-shared no-module no-engine no-apps no-tests no-docs ${tools}
    make -j "$(nproc)" build_libs
    make install_dev

    # ngx_brotli, with the Brotli library built for ARM in its deps/brotli/out (as for amd64)
    cp -r ${BUILD_PATH}/ngx_brotli ${BUILD_PATH}/armhf/ngx_brotli
    rm -rf ${BUILD_PATH}/armhf/ngx_brotli/deps/brotli/out
    cmake -S ${BUILD_PATH}/armhf/ngx_brotli/deps/brotli -B ${BUILD_PATH}/armhf/ngx_brotli/deps/brotli/out \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_C_COMPILER=${TOOLS_PATH}/arm-cc \
        -DCMAKE_AR=${TOOLS_PATH}/arm-ar -DCMAKE_RANLIB=${TOOLS_PATH}/arm-ranlib -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DBROTLI_DISABLE_TESTS=ON -DCMAKE_C_FLAGS='-O2 -fPIC'
    cmake --build ${BUILD_PATH}/armhf/ngx_brotli/deps/brotli/out -j "$(nproc)" --target brotlienc brotlicommon
}

# Builds Nginx for the ARM models, with the libraries build_arm_libraries built.
function build_arm_nginx() {
    local deps=${BUILD_PATH}/armhf/deps

    cd ${BUILD_PATH}/armhf
    tar -xzf ${BUILD_PATH}/nginx-${VERSION}.tar.gz
    cd nginx-${VERSION}
    # (Zig's compiler is Clang, which finds a sign comparison in musl's own CMSG_NXTHDR macro: not an error in Nginx)
    ./configure "${NGINX_OPTIONS[@]}" \
        --crossbuild=Linux::arm \
        --with-cc=${TOOLS_PATH}/arm-cc \
        --add-module=${BUILD_PATH}/armhf/ngx_brotli \
        --with-cc-opt="-static -O2 -Wno-error=sign-compare -I${deps}/include" \
        --with-ld-opt="-static -L${deps}/lib"
    make -j "$(nproc)"
    arm-none-eabi-strip objs/nginx
}

# Copies a build of Nginx to its architecture's output folder, after checking that it's really static and runs.
#
# $1 arch   The architecture (amd64 or armhf)
# $2 source The folder of Nginx's source it was built in
function output_nginx() {
    local arch="$1" source="$2"
    local output=${OUTPUT_ROOT}/${arch}

    if [ "${arch}" = armhf ]; then
        if arm-none-eabi-readelf -l ${source}/objs/nginx | grep 'program interpreter' > /dev/null; then
            echo "nginx (armhf) isn't static"

            exit 1
        fi
    elif ldd ${source}/objs/nginx 2>&1 | grep '=>' > /dev/null; then
        echo "nginx isn't static"

        exit 1
    fi

    rm -rf ${output}
    mkdir -p ${output}/params
    cp ${source}/objs/nginx ${output}/
    # Nginx's standard parameter files (MIME types, FastCGI / SCGI / uWSGI parameters), which configurations include
    cp ${source}/conf/{mime.types,fastcgi.conf,fastcgi_params,scgi_params,uwsgi_params} ${output}/params/

    if [ "${arch}" = armhf ]; then
        qemu-arm -cpu cortex-a9 ${output}/nginx -V > ${BUILD_PATH}/armhf/version.txt 2>&1
        cat ${BUILD_PATH}/armhf/version.txt
        grep -q "nginx/${VERSION}" ${BUILD_PATH}/armhf/version.txt
        grep -q 'built with OpenSSL' ${BUILD_PATH}/armhf/version.txt
    else
        ${output}/nginx -V
    fi
}

# Checks that the ARM build serves a page over HTTPS, compressed with Brotli and with gzip, under QEMU - before it's
# copied to its output folder (build_static.sh takes an output folder that isn't empty as built).
#
# $1 nginx The ARM build
function check_arm_nginx() {
    local nginx="$1"
    local test=${BUILD_PATH}/armhf/test
    local url=https://127.0.0.1:18443/
    local pid

    mkdir -p ${test}/conf ${test}/logs ${test}/temp ${test}/html
    printf '%2000s\n' 'Hello from Nginx on ARM' > ${test}/html/index.html
    openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 1 \
        -keyout ${test}/conf/key.pem -out ${test}/conf/cert.pem 2> /dev/null
    {
        echo 'daemon off;'
        echo 'master_process off;'
        echo 'error_log logs/error.log;'
        echo 'events { worker_connections 16; }'
        echo 'http {'
        echo '    brotli on;'
        echo '    gzip on;'
        echo '    server {'
        echo '        listen 127.0.0.1:18443 ssl;'
        echo '        ssl_certificate cert.pem;'
        echo '        ssl_certificate_key key.pem;'
        echo "        root ${test}/html;"
        echo '    }'
        echo '}'
    } > ${test}/conf/nginx.conf
    qemu-arm -cpu cortex-a9 ${nginx} -p ${test}/ -t
    qemu-arm -cpu cortex-a9 ${nginx} -p ${test}/ &
    pid=$!

    for i in $(seq 1 30); do
        curl -sk -o /dev/null ${url} && break
        sleep 1
    done

    # (grep reading everything: with pipefail, grep -q stopping early can fail the pipe - SIGPIPE)
    curl -sk ${url} | grep 'Hello from Nginx on ARM' > /dev/null
    curl -sk -H 'Accept-Encoding: br' -D - -o /dev/null ${url} | grep -i '^content-encoding: br' > /dev/null
    curl -sk -H 'Accept-Encoding: gzip' -D - -o /dev/null ${url} | grep -i '^content-encoding: gzip' > /dev/null
    kill ${pid}
    wait ${pid} 2> /dev/null || true
}

function run() {
    # Clean start
    if [ -d ${BUILD_PATH} ]; then
        rm -rf ${BUILD_PATH}
    fi
    mkdir -p ${BUILD_PATH}

    download
    build_brotli
    build_nginx
    output_nginx amd64 ${BUILD_PATH}/nginx-${VERSION}

    make_tools
    build_arm_libraries
    build_arm_nginx
    check_arm_nginx ${BUILD_PATH}/armhf/nginx-${VERSION}/objs/nginx
    output_nginx armhf ${BUILD_PATH}/armhf/nginx-${VERSION}

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_ROOT})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R "${HOST_IDS:-1000:1000}" /data/packages
}

run
