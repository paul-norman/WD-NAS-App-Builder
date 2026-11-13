# PHP 8.5 (the PHP app's version), to install phpBB's PHP packages with Composer: they're plain PHP (nothing
# compiled), so the image's system doesn't matter to the NAS
FROM php:8.5-cli-alpine3.22

ENV LANG=C.UTF-8

# Composer unpacks its packages with unzip (the image's PHP has no zip extension); the run-as helper is fully static
# (musl) for each architecture - gcc builds the Intel one, Zig cross-compiles the ARM one, and QEMU and Python check it
RUN apk add --no-cache bash build-base file python3 qemu-arm unzip wget zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
