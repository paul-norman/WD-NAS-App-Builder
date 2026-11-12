FROM alpine:3.22

# A fully static (musl) build, depending on none of the NAS's own (old) libraries. Zig (cross-compiles the ARM models'
# build), ARM binutils (strip, readelf), QEMU (runs its configure's tests and checks it), curl and OpenSSL (its check
# over HTTPS) are for the ARM models
RUN apk add --no-cache bash binutils-arm-none-eabi build-base ca-certificates cmake curl linux-headers openssl perl \
    qemu-arm wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
