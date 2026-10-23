FROM alpine:3.22

# Icecast, ezstream, an audio-only ffmpeg and the run-as helper, all built fully static (musl)
RUN apk add --no-cache bash binutils bsd-compat-headers build-base check-dev cmake file libogg-dev libogg-static libvorbis-dev \
	libvorbis-static libxml2-dev libxml2-static libxslt-dev libxslt-static linux-headers nasm pkgconf wget xz xz-dev \
	xz-static zlib-dev zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
