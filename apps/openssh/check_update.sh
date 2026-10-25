#!/bin/sh
# Weekly (from root's crontab, see init.sh): checks for a new OpenSSH release and shows it as a NAS alert (once per
# release). Can also be run by hand

APP_PATH="$(dirname "$(readlink -f "$0")")"
LAST_FILE="$(dirname "${APP_PATH}")/_openssh/last_update_alert"
RELEASES="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/"

# (the app's 10.6.1 is OpenSSH's 10.6p1)
INSTALLED="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/\.\([0-9]*\)$/p\1/')"
if command -v curl > /dev/null; then
	RESPONSE="$(curl -sf --max-time 20 "${RELEASES}")"
else
	RESPONSE="$(wget -qO- "${RELEASES}")"
fi
LATEST="$(echo "${RESPONSE}" | grep -o 'openssh-[0-9][0-9.]*p[0-9]*\.tar\.gz' | sed 's/^openssh-//; s/\.tar\.gz$//' \
	| sort -t . -k 1,1n -k 2,2n | tail -n 1)"
[ -n "${LATEST}" ] || exit 0

if [ "${LATEST}" != "${INSTALLED}" ] && [ "${LATEST}" != "$(cat "${LAST_FILE}" 2>/dev/null)" ] && [ -x /usr/sbin/alert_test ]; then
	/usr/sbin/alert_test -a 1501 -p "<br><br><b>OpenSSH ${LATEST}</b> (installed: ${INSTALLED})" -f
	echo "${LATEST}" > "${LAST_FILE}"
	echo "Alert shown: OpenSSH ${LATEST} is available (installed: ${INSTALLED})"
else
	echo "No alert: installed ${INSTALLED}, latest ${LATEST}"
fi
