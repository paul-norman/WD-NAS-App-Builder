FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# changedetection.io's packages come as wheels (their compiled parts checked against the NAS's glibc) into a portable
# Python - apart from three only published as source (built here with gcc: for this glibc, the NAS's); the run-as helper
# is compiled here too, statically; curl checks the build
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
	binutils \
	ca-certificates \
	curl \
	file \
	gcc \
	libc6-dev \
	make \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
