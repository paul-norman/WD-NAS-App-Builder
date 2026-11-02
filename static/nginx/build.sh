#!/bin/bash

# Builds Nginx as a fully static binary, with OpenSSL, PCRE2, zlib and Brotli compression (Google's ngx_brotli) built
# in. All paths are relative to the prefix given at runtime (nginx -p <folder>), so the app keeps its configuration,
# logs and temporary files together

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

ARCH=$(uname -m)

if [ ${ARCH} = 'x86_64' ]; then
    ARCH='amd64'
else
    ARCH='armhf'
fi

BUILD_PATH=/build
OUTPUT_PATH=/data/packages/static/nginx/${VERSION}/${ARCH}

function download() {
    cd ${BUILD_PATH}
    wget -q "https://nginx.org/download/nginx-${VERSION}.tar.gz"
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
    wget -q "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
    wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
    wget -q "https://github.com/google/ngx_brotli/archive/${NGX_BROTLI_COMMIT}.tar.gz" -O ngx_brotli.tar.gz
    wget -q "https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz" -O brotli.tar.gz

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

    # Relative paths are relative to the prefix (overridden at runtime with -p)
    ./configure \
        --prefix=/usr/local/nginx \
        --conf-path=conf/nginx.conf \
        --error-log-path=logs/error.log \
        --http-log-path=logs/access.log \
        --pid-path=logs/nginx.pid \
        --lock-path=logs/nginx.lock \
        --http-client-body-temp-path=temp/client_body \
        --http-proxy-temp-path=temp/proxy \
        --http-fastcgi-temp-path=temp/fastcgi \
        --http-uwsgi-temp-path=temp/uwsgi \
        --http-scgi-temp-path=temp/scgi \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-http_gunzip_module \
        --with-http_auth_request_module \
        --with-http_sub_module \
        --with-http_secure_link_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --add-module=${BUILD_PATH}/ngx_brotli \
        --with-pcre=${BUILD_PATH}/pcre2-${PCRE2_VERSION} \
        --with-pcre-jit \
        --with-zlib=${BUILD_PATH}/zlib-${ZLIB_VERSION} \
        --with-openssl=${BUILD_PATH}/openssl-${OPENSSL_VERSION} \
        --with-openssl-opt='no-shared no-tests no-docs' \
        --with-cc-opt='-static -O2' \
        --with-ld-opt='-static'
    make -j "$(nproc)"
    strip objs/nginx
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

    # Copy to output, after checking that it really is static
    if ldd ${BUILD_PATH}/nginx-${VERSION}/objs/nginx 2>&1 | grep -q '=>'; then
        echo "nginx isn't static"

        exit 1
    fi
    mkdir -p ${OUTPUT_PATH}
    cp ${BUILD_PATH}/nginx-${VERSION}/objs/nginx ${OUTPUT_PATH}/
    # Nginx's standard parameter files (MIME types, FastCGI / SCGI / uWSGI parameters), which configurations include
    mkdir -p ${OUTPUT_PATH}/params
    cp ${BUILD_PATH}/nginx-${VERSION}/conf/{mime.types,fastcgi.conf,fastcgi_params,scgi_params,uwsgi_params} ${OUTPUT_PATH}/params/
    ${OUTPUT_PATH}/nginx -V

    # Create a latest release file for ease of use in packages
    LATEST_PATH="$(dirname ${OUTPUT_PATH})"
    LATEST_PATH="$(dirname ${LATEST_PATH})/latest"
    echo -e "\nCreating a latest release file: ${LATEST_PATH}"
    rm -f ${LATEST_PATH}
    printf '%s' "${VERSION}" > ${LATEST_PATH}

    chown -R 1000:1000 /data/packages
}

run
