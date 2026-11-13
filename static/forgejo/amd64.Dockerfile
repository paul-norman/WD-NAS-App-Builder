FROM alpine:3.22

# Forgejo is an official static program for each architecture; git (with a minimal curl, for HTTPS remotes) and the
# run-as helper are built fully static (musl): with gcc and Alpine's static OpenSSL and zlib for the Intel models,
# cross-compiled with Zig for the ARM ones (OpenSSL and zlib from their source too), and QEMU and Python check the ARM
# programs
RUN apk add --no-cache bash binutils-arm-none-eabi build-base ca-certificates file linux-headers openssl-dev \
	openssl-libs-static perl pkgconf python3 qemu-arm wget xz zig zlib-dev zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
