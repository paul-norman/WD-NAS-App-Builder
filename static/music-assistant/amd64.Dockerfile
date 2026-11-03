# ffmpeg, fully static (musl), for Music Assistant: every audio format and filter FFmpeg has natively, network streams
# (HTTP/HTTPS/HLS - radio and streaming services) through OpenSSL, high quality resampling (libsoxr), and the Opus, MP3
# and Vorbis encoders. (Alpine's static libsoxr uses OpenMP, hence -fopenmp)
FROM alpine:3.22 AS ffmpeg
RUN apk add --no-cache build-base libogg-static libvorbis-dev libvorbis-static libxml2-dev libxml2-static linux-headers nasm \
	openssl-dev openssl-libs-static pkgconf soxr-dev soxr-static wget xz xz-static zlib-dev zlib-static
WORKDIR /build
# Ffmpeg's GPG signature was checked against its release key FCF986EA15E6E293A5644F10B4322F04D67658D8; Opus's checksum
# is Xiph's, LAME's matches SourceForge's SHA1 e3630adf399d8917d4da19b96937b7f9b12774ea
# The sources are downloaded and checked beforehand by build_static.sh (static/music-assistant/downloads), with this
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
		--disable-avdevice --enable-version3 --enable-openssl --enable-libsoxr --enable-libopus --enable-libmp3lame \
		--enable-libvorbis --enable-libxml2 --enable-zlib --enable-lzma && \
	make -j "$(nproc)" && \
	strip ffmpeg ffprobe && \
	cp ffmpeg ffprobe /

FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# Installing Music Assistant's packages on the NAS's Debian version means their compiled parts suit the NAS's libraries,
# even if one has to be built from source rather than downloaded
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	g++ \
	make \
	pkg-config \
	wget && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data

COPY --from=ffmpeg /ffmpeg /ffprobe /opt/
