# A Debian ARM glibc runtime, only to check the ARM models' Tautulli with QEMU's emulator (it uses the NAS's own glibc)
FROM debian:bookworm AS armhf-runtime
RUN dpkg --add-architecture armhf && \
	apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libc6:armhf libgcc-s1:armhf && \
	rm -rf /var/lib/apt/lists/*

FROM debian:bookworm

ENV LANG=C.UTF-8

# Tautulli is pure Python (its packages come with it) and its Python a portable build, so only the run-as helper is
# compiled here - with gcc for the Intel models; for the ARM ones, Zig (fetched by static/tautulli/build.sh) compiles
# it and their Python's launcher, and QEMU and Python check them, with the ARM runtime above
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy --no-install-recommends \
	binutils \
	ca-certificates \
	file \
	gcc \
	libc6-dev \
	python3 \
	qemu-user \
	wget \
	xz-utils && \
	rm -rf /var/lib/apt/lists/*

COPY --from=armhf-runtime / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
