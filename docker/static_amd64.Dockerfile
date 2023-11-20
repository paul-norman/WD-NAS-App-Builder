FROM debian:bullseye

ENV LANG C.UTF-8

RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get upgrade -yy && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	build-essential \
	automake \
	curl \
	git \
	pkg-config

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data