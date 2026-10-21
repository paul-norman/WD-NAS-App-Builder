# iputils' ping, as a fully static (musl) program: unlike BusyBox's (the NAS's own), it can ping without root, through the
# kernel's ICMP sockets for the groups allowed in net.ipv4.ping_group_range (as in Docker containers)
FROM alpine:3.22 AS ping
RUN apk add --no-cache build-base linux-headers meson wget
WORKDIR /build
RUN wget -q https://github.com/iputils/iputils/releases/download/20250605/iputils-20250605.tar.xz && \
	echo "6f213700dbf96b5cc4499ca70cb15ecd69c09f405b06785bb4a1a10b572b6276  iputils-20250605.tar.xz" | sha256sum -c - && \
	tar -xJf iputils-20250605.tar.xz && \
	cd iputils-20250605 && \
	LDFLAGS=-static meson setup build -DUSE_CAP=false -DUSE_IDN=false -DUSE_GETTEXT=false -DBUILD_ARPING=false \
		-DBUILD_CLOCKDIFF=false -DBUILD_TRACEPATH=false -DBUILD_MANS=false -DSKIP_TESTS=true && \
	ninja -C build && \
	strip build/ping/ping && \
	cp build/ping/ping /ping

FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# Installing Uptime Kuma's packages on the NAS's Debian version means its compiled parts (e.g. SQLite) suit the NAS's
# libraries, even if one has to be built from source rather than downloaded; the small tools are built static
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	g++ \
	make \
	python3 \
	unzip \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data

COPY --from=ping /ping /opt/ping
