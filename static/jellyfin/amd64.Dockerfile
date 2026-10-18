FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get upgrade -yy && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	build-essential \
	ca-certificates \
	pkg-config \
	python3-pip \
	unzip \
	wget \
	xz-utils && \
	pip3 install meson ninja

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
