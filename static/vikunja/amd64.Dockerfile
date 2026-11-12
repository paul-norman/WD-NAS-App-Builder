FROM golang:1.27.3-alpine

# Intel: Vikunja is an official static program; the tools built alongside it (sqlite3, a run-as helper) are fully static
# (musl). ARM: Vikunja is built from its source - its web app (Node.js, pnpm) and itself (Go, with Zig as its C compiler
# and linker) - and checked with QEMU's emulator (and curl); Zig cross-compiles the helpers, ARM binutils strip them
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base curl nodejs npm python3 qemu-arm unzip wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
