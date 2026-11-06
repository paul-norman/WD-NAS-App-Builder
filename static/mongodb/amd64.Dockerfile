# MongoDB is built from source with its own build system (Bazel) and compilers (its "toolchain", which it downloads for
# the distribution it's built on): it has none for Debian 11, the NAS's version, so it's built on Ubuntu 20.04 - the
# same glibc (2.31) as the NAS. QEMU's user-mode emulator runs the result on an emulated CPU without AVX, as a check
FROM ubuntu:20.04

ENV LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
	apt-get install -yy \
	binutils \
	build-essential \
	ca-certificates \
	curl \
	git \
	liblzma-dev \
	patchelf \
	perl \
	python3 \
	qemu-user \
	tzdata \
	wget \
	xz-utils \
	zlib1g-dev && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
