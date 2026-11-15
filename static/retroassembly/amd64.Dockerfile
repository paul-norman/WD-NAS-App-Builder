FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# RetroAssembly is built from its source with Node.js (the official build) and pnpm, on the NAS's Debian version: its
# one compiled package (better-sqlite3) then suits the NAS's libraries - built here if its ready-built module doesn't
# (gcc, make, Python). The run-as helper and SQLite's shell are compiled here too
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	curl \
	g++ \
	gcc \
	libc6-dev \
	make \
	python3 \
	unzip \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
