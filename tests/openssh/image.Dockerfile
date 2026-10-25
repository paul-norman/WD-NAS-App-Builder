# A stand-in for the NAS's own SSH server: OpenSSH 8.4p1 - WD's version, and Debian 11's (the NAS's glibc) - set out as
# WD has it by wd.sh; plus WD's PHP version (7.4) for the app's page, BusyBox (as its sh) and curl
FROM php:7.4-cli
RUN printf "deb http://archive.debian.org/debian bullseye main\n" > /etc/apt/sources.list && rm -f /etc/apt/sources.list.d/* \
	&& apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq busybox curl procps openssh-server openssh-client openssl >/dev/null \
	&& rm -rf /var/lib/apt/lists/* && ln -sf /bin/busybox /bin/sh
