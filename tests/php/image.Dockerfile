# A stand-in for the NAS's PHP: WD's version (7.4) with php-fpm, on Debian 11 (the NAS's glibc), plus BusyBox, curl and
# cgi-fcgi (requests straight to php-fpm's socket, as the NAS's Apache sends them)
FROM php:7.4-fpm
RUN printf "deb http://archive.debian.org/debian bullseye main\n" > /etc/apt/sources.list && rm -f /etc/apt/sources.list.d/* \
	&& apt-get update -qq && apt-get install -y -qq busybox curl libfcgi-bin procps >/dev/null && rm -rf /var/lib/apt/lists/*
