FROM alpine:3.22

# Navidrome is an official static program for each architecture; ffmpeg (audio only, with libopus and LAME) and the
# run-as helper are built fully static (musl) - with gcc for the Intel models, cross-compiled with Zig for the ARM ones -
# and QEMU and Python check the ARM programs
RUN apk add --no-cache bash binutils binutils-arm-none-eabi build-base file nasm pkgconf python3 qemu-arm wget xz zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
