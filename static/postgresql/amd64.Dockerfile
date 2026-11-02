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

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
