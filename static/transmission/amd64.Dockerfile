FROM alpine:3.22

# Transmission's daemon and tools, and the run-as helper, all built fully static (musl). Intel: gcc, with OpenSSL and
# zlib from Alpine's static packages, a small curl built by build.sh, and Transmission's other libraries from its own
# source. ARM: Zig cross-compiles all of it (OpenSSL, zlib and curl from their source too), ARM binutils strip it, and
# QEMU and Python check it
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base cmake file linux-headers openssl-dev \
	openssl-libs-static perl pkgconf python3 qemu-arm samurai wget xz zig zlib-dev zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
