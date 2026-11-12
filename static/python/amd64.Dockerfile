# A Debian ARM glibc runtime, only to check the ARM models' Python with QEMU's emulator (it uses the NAS's own glibc)
FROM debian:bookworm
RUN dpkg --add-architecture armhf && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libc6:armhf libgcc-s1:armhf && \
    rm -rf /var/lib/apt/lists/*

FROM alpine:3.22

# Zig compiles the ARM models' Python launcher (for the NAS's glibc, laid out for 64KB pages); QEMU checks it, with the
# Debian ARM runtime above
RUN apk add --no-cache bash ca-certificates python3 qemu-arm wget zig

COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
