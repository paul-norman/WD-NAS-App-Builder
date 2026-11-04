FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# Bugsink's packages come as wheels (those with compiled parts built for old glibc versions - checked against the
# NAS's) and its Python is a portable build, so only the run-as helper is compiled here
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	gcc \
	libc6-dev \
	wget && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
