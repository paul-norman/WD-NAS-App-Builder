# A stand-in for the NAS's MariaDB: WD's version (10.5) on Ubuntu 20.04 (glibc 2.31, as the NAS has) - started by the
# suite as WD starts it, root logging in over the socket without a password - plus WD's PHP version (7.4) for the app's
# page, BusyBox (as its sh) and curl
FROM mariadb:10.5
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php7.4-cli busybox curl >/dev/null \
	&& rm -rf /var/lib/apt/lists/* && ln -sf /bin/busybox /bin/sh
ENTRYPOINT []
