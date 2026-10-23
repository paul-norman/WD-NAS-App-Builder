# The Store's test image with the PHP app's version (8.5), BusyBox sh
FROM php:8.5-cli
RUN apt-get update -qq && apt-get install -y -qq busybox curl python3 procps openssl >/dev/null && rm -rf /var/lib/apt/lists/* \
	&& ln -sf /bin/busybox /bin/sh
