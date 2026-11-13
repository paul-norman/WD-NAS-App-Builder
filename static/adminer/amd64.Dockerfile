FROM alpine:3.22

# Adminer is one PHP file (run by the PHP app's PHP); the run-as helper built alongside it is fully static (musl) for
# each architecture - Zig cross-compiles the ARM one, and QEMU and Python check it
RUN apk add --no-cache bash build-base file python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
