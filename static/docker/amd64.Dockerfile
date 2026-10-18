FROM debian:buster

ENV LANG=C.UTF-8

# WD built the PR4100 kernel with Debian Buster's gcc 8.3.0, so kernel modules are built with exactly the same compiler.
# Buster is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian buster main\ndeb http://archive.debian.org/debian buster-updates main\ndeb http://archive.debian.org/debian-security buster/updates main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

RUN apt-get -o Acquire::Check-Valid-Until=false update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	bc \
	bison \
	build-essential \
	ca-certificates \
	flex \
	kmod \
	libelf-dev \
	libssl-dev \
	wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
