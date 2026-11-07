FROM alpine:3.22

# qbittorrent-nox is a published fully static program; the run-as helper built alongside it is fully static (musl) too,
# and the certificate authorities come from Alpine's list. For the ARM models: Zig (a C cross-compiler with its own
# musl), their binutils (strip) and QEMU's ARM emulator (to check what's built runs)
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base ca-certificates qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
