FROM alpine:3.22

# Intel: MariaDB's own Linux release, cut down (binutils, patchelf) and given a stand-in libsystemd (gcc). ARM: MariaDB
# built from its source, fully static, with clang and LLD (which lays programs out for the ARM models' large memory
# pages) against Alpine's own static ARM libraries (the Alpine ARM system in /armv7, installed with Alpine's ARM signing
# keys - its packages' scripts aren't run here; the links to the shared libraries MariaDB uses taken away, so that its
# build can only find the static ones), with QEMU's emulator (MariaDB's build runs programs it has just built, and its
# checks run the result) and Python (the layout check)
RUN apk add --no-cache alpine-keys bash binutils bison clang cmake file gcc lld llvm make musl-dev ncurses patchelf perl \
    pkgconf python3 qemu-arm wget && \
    mkdir -p /armv7/etc/apk/keys && cp /usr/share/apk/keys/armv7/* /armv7/etc/apk/keys/ && \
    apk add --root /armv7 --arch armv7 --initdb --no-scripts --no-cache \
        -X https://dl-cdn.alpinelinux.org/alpine/v3.22/main -X https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
        musl-dev gcc g++ libstdc++-dev linux-headers fmt-dev ncurses-dev ncurses-static openssl-dev \
        openssl-libs-static pcre2-dev pcre2-static zlib-dev zlib-static && \
    cd /armv7/usr/lib && rm -f libssl.so libcrypto.so libz.so libpcre2-8.so libpcre2-posix.so libncursesw.so

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
