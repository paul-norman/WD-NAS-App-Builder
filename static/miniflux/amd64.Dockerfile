FROM alpine:3.22

# Miniflux is an official static program for each architecture; the run-as helper built alongside it is fully static
# (musl) too - Zig cross-compiles the ARM one, and QEMU and Python check the ARM programs
RUN apk add --no-cache bash build-base file python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
