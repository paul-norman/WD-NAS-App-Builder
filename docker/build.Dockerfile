FROM debian:bullseye

ENV LANG C.UTF-8

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