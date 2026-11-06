FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# Installing Compass Web's packages on the NAS's Debian version means their compiled parts suit the NAS's libraries,
# even if one has to be built from source rather than downloaded; the run-as helper is built static
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	g++ \
	make \
	python3 \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
