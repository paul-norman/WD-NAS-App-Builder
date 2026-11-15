# A Debian ARM glibc runtime, only to check the ARM models' Bugsink with QEMU's emulator (it uses the NAS's own glibc)
FROM debian:bookworm
RUN dpkg --add-architecture armhf && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libc6:armhf libgcc-s1:armhf && \
    rm -rf /var/lib/apt/lists/*

FROM rust:1.99.1-slim-bookworm

ENV LANG=C.UTF-8

# Bugsink's packages come as wheels (those with compiled parts built for old glibc versions - checked against the
# NAS's) and its Python is a portable build, so for the Intel models only the run-as helper is compiled here. The ARM
# models' packages with compiled parts (Rust) are built from their source with Rust and maturin (Zig linking them for
# old glibc versions, laid out for the ARM models' large memory pages); ARM binutils strip and inspect them, and QEMU
# and Python check them, with the Debian ARM runtime above
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
    binutils \
    binutils-arm-linux-gnueabihf \
    ca-certificates \
    file \
    gcc \
    libc6-dev \
    python3 \
    qemu-user \
    wget \
    xz-utils && \
    rm -rf /var/lib/apt/lists/* && \
    rustup target add armv7-unknown-linux-gnueabihf

COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
