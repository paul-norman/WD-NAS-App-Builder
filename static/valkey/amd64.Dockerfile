FROM alpine:3.22

# ValKey, fully static (musl) for the Intel models and the ARM ones: gcc compiles the Intel one (ValKey picks its
# fastest code for the processor it runs on, with gcc's runtime), Zig the ARM one (with its own musl, laid out for their
# large memory pages), and QEMU and Python check the ARM build
RUN apk add --no-cache bash binutils-arm-none-eabi build-base file linux-headers make pkgconf python3 qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
