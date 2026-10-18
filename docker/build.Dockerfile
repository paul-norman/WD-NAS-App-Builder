FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

RUN apt-get update && \
	apt-get upgrade -y && \
	apt-get install -y \
	build-essential \
	openssl \
	git \
	curl \
	wget \
	cmake \
	libxml2 \
	xz-utils \
	tar \
	gzip

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data