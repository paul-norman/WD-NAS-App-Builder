# The ARM models' PHP: Debian's cross-compiler for their processors (armhf) and Debian's own builds of the libraries PHP
# uses, for them. build.sh compiles PHP with these inside this stage's files (kept whole in the final image, and entered
# with chroot), so that the ARM build is made with the same version of PHP as the Intel one, from the same download
FROM debian:bookworm
RUN dpkg --add-architecture armhf && \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf binutils-arm-linux-gnueabihf ca-certificates crossbuild-essential-armhf dpkg-dev file make patchelf \
        pkg-config \
        libargon2-dev:armhf libbz2-dev:armhf libcurl4-openssl-dev:armhf libedit-dev:armhf libfreetype-dev:armhf \
        libgmp-dev:armhf libicu-dev:armhf libjpeg62-turbo-dev:armhf libldap2-dev:armhf libonig-dev:armhf \
        libpng-dev:armhf libpq-dev:armhf libsodium-dev:armhf libsqlite3-dev:armhf libssl-dev:armhf libtidy-dev:armhf \
        libwebp-dev:armhf libxml2-dev:armhf libxslt1-dev:armhf libyaml-dev:armhf libzip-dev:armhf zlib1g-dev:armhf && \
    rm -rf /var/lib/apt/lists/*

FROM alpine:3.22

# static-php-cli builds fully static (musl) binaries, which depend on none of the NAS's own (old) libraries. QEMU checks
# the ARM models' build
RUN apk add --no-cache bash ca-certificates curl qemu-arm wget

# The ARM models' build environment (above)
COPY --from=0 / /armhf-root/

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
