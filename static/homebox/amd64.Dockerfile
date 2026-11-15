FROM golang:1.27.3-alpine

# Intel: Homebox is its official release (a Go program: needs only the NAS's own glibc, of any version). ARM: Homebox is
# built from its source - its web app (Node.js, pnpm) and itself (Go). The tools built alongside it (sqlite3, a run-as
# helper) are fully static (musl) for each - Zig cross-compiles the ARM ones - and QEMU and Python check the ARM programs
RUN apk add --no-cache bash build-base file nodejs npm python3 qemu-arm unzip wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
