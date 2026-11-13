FROM alpine:3.22

# Node.js for the ARM models, built from its source (Node.js publishes no 32-bit ARM builds since version 24): Zig
# cross-compiles it fully static (musl) for their ARMv7 processors, and its build-time tools for 32-bit Intel (V8 makes
# its start-up snapshot with them, and they must match the ARM program's 32-bit memory layout); Python runs Node's
# build, ARM binutils strip it, and QEMU and Python check it
RUN apk add --no-cache bash binutils-arm-none-eabi file linux-headers make python3 qemu-arm wget xz zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
