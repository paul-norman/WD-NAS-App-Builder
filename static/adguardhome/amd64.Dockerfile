FROM alpine:3.22

# AdGuard Home is its official static program for each architecture; the run-as helper is fully static (musl) - built
# with gcc for the Intel models, cross-compiled with Zig for the ARM ones - and QEMU and Python check the ARM programs
RUN apk add --no-cache bash build-base file python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
