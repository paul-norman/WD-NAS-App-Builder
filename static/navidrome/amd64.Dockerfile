FROM alpine:3.22

# Navidrome is an official static program; ffmpeg (audio only, with libopus and LAME) and the run-as helper are built
# fully static (musl)
RUN apk add --no-cache bash binutils build-base nasm pkgconf wget xz

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
