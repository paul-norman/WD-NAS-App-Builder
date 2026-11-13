FROM golang:1.27.3-alpine

# Intel: kvweb is an official static program. ARM: kvweb is built from its source - its web app (Node.js, pnpm) and
# itself (Go). The run-as helper is fully static (musl) for each - Zig cross-compiles the ARM one - and QEMU and Python
# check the ARM programs
RUN apk add --no-cache bash build-base file nodejs npm python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
