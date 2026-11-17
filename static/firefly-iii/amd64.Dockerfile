# Firefly III's release already has its PHP packages and its built web interface (plain PHP and files: nothing to
# compile), so this only unpacks it - and builds its run-as helper, fully static (musl) for each architecture: gcc builds
# the Intel one, Zig cross-compiles the ARM one, and QEMU and Python check it
FROM alpine:3.22

ENV LANG=C.UTF-8

RUN apk add --no-cache bash build-base file python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
