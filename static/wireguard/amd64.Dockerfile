# Builds WireGuard's userspace programs for the NAS, fully static (musl): wireguard-go (Go), wg (C) and qrencode (C, for
# the management page's QR codes). Zig (cross-compiles the C programs), ARM binutils (strip, readelf) and QEMU (checks
# the programs) are for the ARM models
FROM golang:1.27.3-alpine

RUN apk add --no-cache bash binutils-arm-none-eabi build-base cmake file linux-headers qemu-arm wget xz zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
