# PHP 8.5 (the PHP app's version), to install BookStack's PHP packages with Composer: they're plain PHP (nothing
# compiled), so the image's Debian version doesn't matter to the NAS
FROM php:8.5-cli-bookworm

ENV LANG=C.UTF-8

# Composer unpacks its packages with unzip (the image's PHP has no zip extension); gcc builds the run-as helper
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	ca-certificates \
	gcc \
	libc6-dev \
	unzip \
	wget && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
