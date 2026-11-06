FROM alpine:3.22

# Prometheus is an official static program; the run-as helper built alongside it is fully static (musl) too
# Zig (cross-compiles the helpers), ARM binutils (strip) and QEMU (checks the programs) are for the ARM models
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
