# The ARM models' PostgreSQL: an Alpine system with clang and LLD (which lays programs and libraries out for the ARM
# models' large memory pages), Alpine's own static ARM libraries for PostgreSQL, PostGIS and PROJ (the Alpine ARM system
# in /armv7, installed with Alpine's ARM signing keys - its packages' scripts aren't run here; its shared libraries'
# links taken away, but musl's - libc.so - so that only the static ones are found), and QEMU's emulator (configure's
# test programs, and PostGIS and the extensions ask PostgreSQL's pg_config, an ARM program, how it was built). Some of
# Alpine's static libraries hold GCC's link-time optimisation code, which LLD can't link: those are deleted. build.sh
# builds PostgreSQL inside this stage's files (kept whole in the final image, and entered with chroot), so that the ARM
# build is made from the same versions as the Intel one
FROM alpine:3.22
RUN apk add --no-cache alpine-keys bash binutils-arm-none-eabi bison clang cmake file flex lld llvm make perl pkgconf \
        protobuf-c-compiler qemu-arm sqlite && \
    mkdir -p /armv7/etc/apk/keys && cp /usr/share/apk/keys/armv7/* /armv7/etc/apk/keys/ && \
    apk add --root /armv7 --arch armv7 --initdb --no-scripts --no-cache \
        -X https://dl-cdn.alpinelinux.org/alpine/v3.22/main -X https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
        musl-dev gcc g++ libstdc++-dev linux-headers icu-data-full icu-dev icu-static json-c-dev libedit-dev \
        libedit-static libxml2-dev libxml2-static lz4-dev lz4-static ncurses-dev ncurses-static openssl-dev \
        openssl-libs-static protobuf-c-dev sqlite-dev sqlite-static xz-dev xz-static zlib-dev zlib-static zstd-dev \
        zstd-static && \
    for archive in /armv7/usr/lib/*.a; do \
        mkdir -p /tmp/lto && cd /tmp/lto && arm-none-eabi-ar x "${archive}" && \
        if arm-none-eabi-readelf -S ./* 2>/dev/null | grep -q 'gnu\.lto_'; then rm "${archive}"; fi; \
        cd / && rm -rf /tmp/lto; \
    done && \
    find /armv7/usr/lib /armv7/lib -maxdepth 1 -name '*.so' ! -name libc.so -delete

FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# PostgreSQL's build tools, and the libraries it's built with (bundled with it, as the NAS may lack them)
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	bison \
	file \
	build-essential \
	ca-certificates \
	flex \
	libgmp-dev \
	libicu-dev \
	libjson-c-dev \
	libprotobuf-c-dev \
	libsqlite3-dev \
	libxml2-dev \
	liblz4-dev \
	libreadline-dev \
	libzstd-dev \
	patchelf \
	perl \
	pkg-config \
	protobuf-c-compiler \
	sqlite3 \
	python3-pip \
	uuid-dev \
	wget \
	zlib1g-dev

# PROJ needs a newer CMake than Bullseye's (3.18) - only the build tool, the libraries stay Bullseye's
RUN pip3 install --no-cache-dir cmake==3.31.6

# The ARM models' build environment (above)
COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
