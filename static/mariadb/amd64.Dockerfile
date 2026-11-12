# The ARM models' MariaDB: Debian's cross-compiler for their processors (armhf), Debian's own builds of the libraries
# MariaDB uses, for them, and QEMU's emulator (MariaDB's build runs programs it has just built). build.sh compiles
# MariaDB with these inside this stage's files (kept whole in the final image, and entered with chroot), so that the ARM
# build is made from the same version as the Intel one
FROM debian:bookworm
RUN dpkg --add-architecture armhf && \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bison ca-certificates cmake crossbuild-essential-armhf dpkg-dev file make patchelf pkg-config \
        qemu-user-static \
        libcrypt-dev:armhf libfmt-dev:armhf libncurses-dev:armhf libpcre2-dev:armhf libssl-dev:armhf \
        zlib1g-dev:armhf && \
    rm -rf /var/lib/apt/lists/*

FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# QEMU's emulator checks the ARM models' build
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	binutils \
	ca-certificates \
	gcc \
	patchelf \
	qemu-user \
	wget

# The ARM models' build environment (above)
COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
