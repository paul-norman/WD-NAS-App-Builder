# The test suites' image like the NAS (see tests/README.md): WD's PHP version (7.4), Debian 11's glibc (2.31, as the NAS has),
# BusyBox sh and OpenSSL 1.1 - plus curl and Python for the test servers and tools (Debian 11's packages are on
# archive.debian.org)
FROM php:7.4-cli
RUN printf "deb http://archive.debian.org/debian bullseye main\n" > /etc/apt/sources.list && rm -f /etc/apt/sources.list.d/* \
	&& apt-get update -qq && apt-get install -y -qq busybox curl python3 procps >/dev/null && rm -rf /var/lib/apt/lists/* \
	&& ln -sf /bin/busybox /bin/sh
