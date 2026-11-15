# The test suites' image like the NAS (as tests/images/php74.Dockerfile: WD's PHP version, Debian 11's glibc, BusyBox
# sh, curl and Python) - plus iptables (legacy, as the NAS's), iproute2 (a network namespace as a device on the LAN)
# and dig, for AdGuard Home's DNS forwarding (Debian 11's packages are on archive.debian.org)
FROM php:7.4-cli
RUN printf "deb http://archive.debian.org/debian bullseye main\n" > /etc/apt/sources.list && rm -f /etc/apt/sources.list.d/* \
	&& apt-get update -qq \
	&& apt-get install -y -qq busybox curl python3 procps iptables iproute2 dnsutils >/dev/null \
	&& rm -rf /var/lib/apt/lists/* \
	&& update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null \
	&& ln -sf /bin/busybox /bin/sh
