FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# linkding's packages come as wheels (their compiled parts checked against the NAS's glibc), but for its web server
# (uWSGI), compiled here on the NAS's Debian version; its Python is a portable build, and Node.js (downloaded by
# static/linkding/build.sh) only builds its web interface. The run-as helper is compiled here too
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	curl \
	gcc \
	libc6-dev \
	make \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
