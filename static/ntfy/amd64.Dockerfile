FROM golang:1.27.3-alpine

# Intel: ntfy is an official static program; the run-as helper built alongside it is fully static (musl) too. ARM: ntfy
# is built from its source - its web app (Node.js), documentation (Python's mkdocs) and itself (Go, with Zig as its C
# compiler and linker) - and checked with QEMU's emulator (and curl). Zig also cross-compiles the helper; ARM binutils
# strip it
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base curl nodejs npm python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
