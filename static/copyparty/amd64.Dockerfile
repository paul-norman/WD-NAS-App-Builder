# ffmpeg, fully static (musl), for CopyParty: thumbnails of videos (every video format FFmpeg decodes natively - H.264,
# HEVC, VP8/9, MPEG-4... - out as WebP or JPEG) and of audio (spectrograms), media tags (ffprobe), and audio transcoding
# for its web player (Opus, MP3; high quality resampling through libsoxr). Alpine's static libsoxr uses OpenMP, hence
# -fopenmp
FROM alpine:3.22 AS ffmpeg
RUN apk add --no-cache build-base libogg-static libvorbis-dev libvorbis-static libwebp-dev libwebp-static linux-headers \
	nasm pkgconf soxr-dev soxr-static wget xz xz-dev xz-static zlib-dev zlib-static
WORKDIR /build
# Ffmpeg's GPG signature was checked against its release key FCF986EA15E6E293A5644F10B4322F04D67658D8; Opus's checksum
# is Xiph's, LAME's matches SourceForge's SHA1 e3630adf399d8917d4da19b96937b7f9b12774ea
# The sources are downloaded and checked beforehand by build_static.sh (static/copyparty/downloads), with this
# repository's mirror to fall back on
COPY .downloads/opus-1.6.1.tar.gz ./
RUN tar -xzf opus-1.6.1.tar.gz && cd opus-1.6.1 && \
	./configure --prefix=/usr/local --disable-shared --enable-static --disable-doc --disable-extra-programs && \
	make -j "$(nproc)" && make install
COPY .downloads/lame-4.0.tar.gz ./
RUN tar -xzf lame-4.0.tar.gz && cd lame-4.0 && \
	./configure --prefix=/usr/local --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder && \
	make -j "$(nproc)" && make install
COPY .downloads/ffmpeg-9.0.2.tar.xz ./
RUN tar -xJf ffmpeg-9.0.2.tar.xz && cd ffmpeg-9.0.2 && \
	PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure --pkg-config-flags=--static --extra-ldflags="-static -fopenmp" \
		--enable-static --disable-shared --disable-doc --disable-debug --disable-ffplay --disable-autodetect \
		--disable-avdevice --disable-network --enable-version3 --enable-libsoxr --enable-libopus --enable-libmp3lame \
		--enable-libvorbis --enable-libwebp --enable-zlib --enable-lzma && \
	make -j "$(nproc)" && \
	strip ffmpeg ffprobe && \
	cp ffmpeg ffprobe /

# A Debian ARM glibc runtime, only to check the ARM models' copyparty with QEMU's emulator (it uses the NAS's own glibc)
FROM debian:bookworm AS armhf-runtime
RUN dpkg --add-architecture armhf && \
	apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libc6:armhf libgcc-s1:armhf && \
	rm -rf /var/lib/apt/lists/*

FROM debian:bookworm

ENV LANG=C.UTF-8

# The Intel models' packages are PyPI's wheels (their compiled parts built for old glibc versions - checked against the
# NAS's), so only the run-as helper is compiled for them here. The ARM models' are cross-compiled with Zig (by
# static/copyparty/build.sh): ffmpeg and its libraries, and the packages' compiled parts with theirs - CMake and
# pkg-config for those; ARM binutils strip and inspect them, and QEMU and Python check them, with the ARM runtime above
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
	binutils \
	binutils-arm-linux-gnueabihf \
	ca-certificates \
	cmake \
	file \
	gcc \
	libc6-dev \
	make \
	pkg-config \
	python3 \
	qemu-user \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

COPY --from=armhf-runtime / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data

COPY --from=ffmpeg /ffmpeg /ffprobe /opt/
