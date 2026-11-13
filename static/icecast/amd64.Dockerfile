FROM alpine:3.22

# Icecast, ezstream, an audio-only ffmpeg and the run-as helper, all built fully static (musl). Intel: gcc, with
# Alpine's static libraries. ARM: clang and LLD (laid out for the ARM models' large memory pages), against Alpine's own
# static ARM libraries (the Alpine ARM system in /armv7, installed with Alpine's ARM signing keys - its packages' scripts
# aren't run here; any static library holding GCC's link-time optimisation code, which LLD can't link, is deleted);
# QEMU runs configure's test programs and checks the result, with Python
RUN apk add --no-cache alpine-keys bash binutils binutils-arm-none-eabi bsd-compat-headers build-base check-dev clang \
	cmake file libogg-dev libogg-static libvorbis-dev libvorbis-static libxml2-dev libxml2-static libxslt-dev \
	libxslt-static linux-headers lld nasm pkgconf python3 qemu-arm wget xz xz-dev xz-static zlib-dev zlib-static

RUN mkdir -p /armv7/etc/apk/keys && cp /usr/share/apk/keys/armv7/* /armv7/etc/apk/keys/ && \
	apk add --root /armv7 --arch armv7 --initdb --no-scripts --no-cache \
		-X https://dl-cdn.alpinelinux.org/alpine/v3.22/main -X https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
		musl-dev gcc g++ libstdc++-dev linux-headers bsd-compat-headers check-dev \
		libgcrypt-static libgpg-error-static libogg-dev libogg-static libvorbis-dev libvorbis-static libxml2-dev \
		libxml2-static libxslt-dev libxslt-static xz-dev xz-static zlib-dev zlib-static && \
	for archive in /armv7/usr/lib/*.a; do \
		mkdir -p /tmp/lto && cd /tmp/lto && arm-none-eabi-ar x "${archive}" && \
		if arm-none-eabi-readelf -S ./* 2>/dev/null | grep -q 'gnu\.lto_'; then echo "LTO: ${archive}"; rm "${archive}"; fi; \
		cd / && rm -rf /tmp/lto; \
	done

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
