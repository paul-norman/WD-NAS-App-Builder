# The PHP 7.4 test image (see tests/images) with iptables - legacy iptables, as WD's NAS has
ARG BASE=nas-test-php74
FROM ${BASE}
RUN apt-get update -qq && apt-get install -y -qq iptables >/dev/null && rm -rf /var/lib/apt/lists/* \
	&& update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null
