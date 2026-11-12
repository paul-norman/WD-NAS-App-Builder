FROM alpine:3.22

# Intel: static-php-cli builds fully static (musl) binaries, which depend on none of the NAS's own (old) libraries. ARM:
# armhf.sh builds PHP fully static too, with clang and LLD (laid out for the ARM models' large memory pages), against
# Alpine's own static ARM libraries (the Alpine ARM system in /armv7, installed with Alpine's ARM signing keys - its
# packages' scripts aren't run here); QEMU runs configure's test programs and checks the result. Some of Alpine's static
# libraries hold GCC's link-time optimisation code, which LLD can't link (e.g. Brotli's, libwebp's): those are deleted,
# and armhf.sh builds the ones PHP needs from their source (with curl, whose own static library needs several, and
# OpenLDAP's client libraries, whose own need SASL, Kerberos...)
RUN apk add --no-cache alpine-keys autoconf bash binutils-arm-none-eabi bison ca-certificates clang cmake curl lld make \
    pkgconf python3 qemu-arm re2c wget xz

RUN mkdir -p /armv7/etc/apk/keys && cp /usr/share/apk/keys/armv7/* /armv7/etc/apk/keys/ && \
    apk add --root /armv7 --arch armv7 --initdb --no-scripts --no-cache \
        -X https://dl-cdn.alpinelinux.org/alpine/v3.22/main -X https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
        musl-dev gcc g++ libstdc++-dev linux-headers \
        bzip2-dev bzip2-static freetype-dev freetype-static gettext-dev gettext-static icu-data-full icu-dev icu-static \
        libedit-dev libedit-static libgcrypt-static libgpg-error-static libjpeg-turbo-dev libjpeg-turbo-static \
        libpng-dev libpng-static libpq-dev libsodium-dev libsodium-static libxml2-dev libxml2-static libxslt-dev \
        libxslt-static ncurses-dev ncurses-static oniguruma-dev openssl-dev openssl-libs-static \
        sqlite-dev sqlite-static tidyhtml-dev tidyhtml-static yaml-dev yaml-static zlib-dev zlib-static zstd-dev \
        zstd-static xz-dev xz-static && \
    for archive in /armv7/usr/lib/*.a; do \
        mkdir -p /tmp/lto && cd /tmp/lto && arm-none-eabi-ar x "${archive}" && \
        if arm-none-eabi-readelf -S ./* 2>/dev/null | grep -q 'gnu\.lto_'; then rm "${archive}"; fi; \
        cd / && rm -rf /tmp/lto; \
    done

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
