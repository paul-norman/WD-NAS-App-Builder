FROM alpine:3.22

# The Store's signature checker is a fully static (musl) C program. Zig (cross-compiles it), ARM binutils (strip) and
# QEMU (checks it) are for the ARM models
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
