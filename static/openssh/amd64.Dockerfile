# Builds OpenSSH for the NAS, fully static against musl: no part of it depends on the NAS's own libraries, and musl reads
# /etc/passwd and /etc/shadow itself (a static glibc build would load the NAS's NSS libraries for every login)
FROM alpine:3.22

# Zig (the ARM models' compiler), ARM binutils (strip), perl (OpenSSL's build) and QEMU (checks the ARM programs) are
# for the ARM models
RUN apk add --no-cache bash binutils-arm-none-eabi build-base file linux-headers openssl-dev openssl-libs-static perl \
    qemu-arm wget zig zlib-dev zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
