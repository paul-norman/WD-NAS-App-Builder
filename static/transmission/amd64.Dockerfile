FROM alpine:3.22

# Transmission's daemon and tools, and the run-as helper, all built fully static (musl): OpenSSL and zlib from Alpine's
# static packages, a small curl built by build.sh, and Transmission's other libraries from its own source
RUN apk add --no-cache bash binutils build-base cmake file linux-headers openssl-dev openssl-libs-static perl pkgconf \
	python3 samurai xz zlib-dev zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
