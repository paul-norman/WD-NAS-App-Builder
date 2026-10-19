#!/bin/sh
# Switches Entware's package downloads from HTTP to HTTPS: updates the installed packages, installs wget-ssl and the CA
# certificates it needs, then checks that the package lists can really be downloaded over HTTPS (switching back if not). Run by install.sh and by
# the management page; can also be run by hand

OPKG=/opt/bin/opkg
CONF=/opt/etc/opkg.conf
export PATH="/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -x "${OPKG}" ] || [ ! -f "${CONF}" ]; then
	echo "Entware is not installed (or /opt is not mounted)"
	exit 1
fi
if ! grep -q "http://bin.entware.net" "${CONF}"; then
	echo "Entware already downloads packages over HTTPS"
	exit 0
fi

# wget-ssl's dependencies aren't versioned, so older libraries (e.g. OpenSSL 1.1 in installs taken over from the
# WDCommunity app) count as good enough, but the current wget-ssl can't start with them. So bring everything up to
# date first, while downloads still work
echo "Updating the installed packages"
if ! "${OPKG}" update || ! "${OPKG}" upgrade; then
	echo "The installed packages could not be updated, so packages are still downloaded over HTTP"
	exit 1
fi

echo "Installing wget-ssl and ca-bundle"
if ! "${OPKG}" install wget-ssl ca-bundle; then
	echo "Could not install wget-ssl and ca-bundle, so packages are still downloaded over HTTP"
	exit 1
fi

# Current versions of opkg link /opt/bin/wget to wget-ssl, older ones may not
if [ ! -e /opt/bin/wget ] && [ -x /opt/libexec/wget-ssl ]; then
	echo "Linking /opt/bin/wget to wget-ssl"
	ln -sf /opt/libexec/wget-ssl /opt/bin/wget
fi

# /opt/bin comes first in the PATH, so a wget-ssl that can't start would leave opkg unable to download anything: remove
# it again, so that opkg goes back to the NAS's own wget
if ! /opt/bin/wget --version > /dev/null 2>&1; then
	echo "wget-ssl doesn't start ($(/opt/bin/wget --version 2>&1 | head -1)), so removing it again"
	"${OPKG}" remove wget-ssl
	rm -f /opt/bin/wget
	exit 1
fi

echo "Switching package downloads to HTTPS"
cp "${CONF}" "${CONF}.http"
sed -i 's|http://bin.entware.net|https://bin.entware.net|g' "${CONF}"
if ! "${OPKG}" update; then
	echo "The package lists could not be downloaded over HTTPS, so switching back to HTTP"
	mv "${CONF}.http" "${CONF}"
	exit 1
fi
rm -f "${CONF}.http"
echo "Entware now downloads packages over HTTPS"
