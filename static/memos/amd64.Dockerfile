FROM alpine:3.22

# Memos is an official static program; the tools built alongside it (sqlite3, a run-as helper) are fully static (musl)
# Zig (cross-compiles the helpers), ARM binutils (strip) and QEMU (checks the programs) are for the ARM models
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base qemu-arm unzip wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
