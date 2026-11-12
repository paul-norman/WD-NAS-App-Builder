# The ARM models' PostgreSQL: Debian's cross-compiler for their processors (armhf), Debian's own builds of the libraries
# PostgreSQL, PostGIS and PROJ use, for them, and QEMU's emulator (PostGIS and the extensions ask PostgreSQL's pg_config,
# an ARM program, how it was built). build.sh compiles them with these inside this stage's files (kept whole in the
# final image, and entered with chroot), so that the ARM build is made from the same versions as the Intel one
FROM debian:bookworm
RUN dpkg --add-architecture armhf && \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bison ca-certificates cmake crossbuild-essential-armhf dpkg-dev file flex make patchelf perl pkg-config \
        protobuf-c-compiler qemu-user-static sqlite3 \
        libgmp-dev:armhf libicu-dev:armhf libjson-c-dev:armhf liblz4-dev:armhf libprotobuf-c-dev:armhf \
        libreadline-dev:armhf libsqlite3-dev:armhf libssl-dev:armhf libxml2-dev:armhf libzstd-dev:armhf \
        uuid-dev:armhf zlib1g-dev:armhf && \
    rm -rf /var/lib/apt/lists/*

FROM debian:bullseye

ENV LANG=C.UTF-8

# Bullseye (the NAS's Debian version) is end of life, so its packages are only on the archive mirror
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	rm -f /etc/apt/sources.list.d/*

# PostgreSQL's build tools, and the libraries it's built with (bundled with it, as the NAS may lack them)
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yy \
	bison \
	file \
	build-essential \
	ca-certificates \
	flex \
	libgmp-dev \
	libicu-dev \
	libjson-c-dev \
	libprotobuf-c-dev \
	libsqlite3-dev \
	libxml2-dev \
	liblz4-dev \
	libreadline-dev \
	libzstd-dev \
	patchelf \
	perl \
	pkg-config \
	protobuf-c-compiler \
	sqlite3 \
	python3-pip \
	uuid-dev \
	wget \
	zlib1g-dev

# PROJ needs a newer CMake than Bullseye's (3.18) - only the build tool, the libraries stay Bullseye's
RUN pip3 install --no-cache-dir cmake==3.31.6

# QEMU's emulator checks the ARM models' build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -yy qemu-user && rm -rf /var/lib/apt/lists/*

# The ARM models' build environment (above)
COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
