#!/bin/sh
# Gets and renews the default certificate with lego (an ACME client, e.g. for Let's Encrypt), using a DNS-01 challenge:
# lego briefly adds a TXT record through the DNS provider's API, so nothing on the NAS needs to be reachable from the
# internet. Settings are in _nginx/acme/settings.conf, the provider's credentials in _nginx/acme/credentials.env (both
# written by the app's page, root-only).
#   cert.sh issue    - get a certificate now (first on the CA's staging server, where it has one)
#   cert.sh renew    - renew the certificate if it's due (daily, from root's crontab)
#   cert.sh deploy   - install the certificate lego got and reload Nginx (lego's deploy hook)

APP_PATH="$(dirname "$(readlink -f "$0")")"
DATA_PATH="$(dirname "${APP_PATH}")/_nginx"
ACME_PATH="${DATA_PATH}/acme"
LEGO="${APP_PATH}/binaries/lego"
LOG=/tmp/debug_apkg

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') nginx/cert.sh $*" >> ${LOG}
	echo "$*"
}

# The settings: ACME_DOMAIN, ACME_EMAIL, ACME_SERVER, ACME_PROVIDER (validated and quoted by the page)
load_settings() {
	if [ ! -f "${ACME_PATH}/settings.conf" ]; then
		echo "No certificate settings yet - set them up on the app's page"
		return 1
	fi
	. "${ACME_PATH}/settings.conf"
	[ -n "${ACME_DOMAIN}" ] && [ -n "${ACME_EMAIL}" ] && [ -n "${ACME_PROVIDER}" ] && [ -n "${ACME_SERVER}" ]
}

# lego's own DNS settings, given as "other variables" on the page (e.g. LEGO_DNS_RESOLVERS="1.1.1.1:53" where a local
# DNS server answers for the domain itself, or LEGO_DISABLE_CNAME_SUPPORT="true" where a wildcard CNAME would otherwise
# send the challenge record elsewhere): lego only reads its env file for the DNS provider's settings, so these are
# passed to it in its environment
export_lego_settings() {
	while IFS= read -r line; do
		case "${line}" in
			LEGO_DNS_RESOLVERS=*|LEGO_DNS_TIMEOUT=*|LEGO_DNS_PROPAGATION_WAIT=*|LEGO_DNS_PROPAGATION_DISABLE_ANS=*|LEGO_DNS_PROPAGATION_DISABLE_RNS=*|LEGO_DISABLE_CNAME_SUPPORT=*)
				value="${line#*=}"
				value="${value#\"}"
				export "${line%%=*}=${value%\"}"
				;;
		esac
	done < "${ACME_PATH}/credentials.env"
}

# Runs lego for the domain and its wildcard: $1 = server, $2 = storage folder, then any extra options
lego_run() {
	export_lego_settings
	server="$1"
	path="$2"
	shift 2
	set -- run --accept-tos --email "${ACME_EMAIL}" --server "${server}" --dns "${ACME_PROVIDER}" \
		--domains "${ACME_DOMAIN}" --domains "*.${ACME_DOMAIN}" --cert.name default --path "${path}" \
		--env-file "${ACME_PATH}/credentials.env" "$@"
	[ -n "${ACME_EAB_KID}" ] && set -- "$@" --eab --eab.kid "${ACME_EAB_KID}" --eab.hmac "${ACME_EAB_HMAC}"
	"${LEGO}" --log.format text "$@"
}

# The CA's staging server (certificates that browsers don't trust, but with much higher rate limits)
staging_server() {
	case "$1" in
		letsencrypt) echo letsencrypt-staging ;;
		googletrust) echo googletrust-staging ;;
	esac
}

# A fingerprint of everything that decides whether getting a certificate works (the settings and credentials), so that
# the staging server is only tried again after a change
settings_fingerprint() {
	cat "${ACME_PATH}/settings.conf" "${ACME_PATH}/credentials.env" | md5sum | cut -d ' ' -f 1
}

issue() {
	load_settings || return 1
	staging="$(staging_server "${ACME_SERVER}")"
	if [ -n "${staging}" ] && [ "$(cat "${ACME_PATH}/staging.ok" 2>/dev/null)" = "$(settings_fingerprint)" ]; then
		log "The staging server already worked with these settings, so going straight to the real certificate"
		staging=""
	fi
	if [ -n "${staging}" ]; then
		log "Trying the staging server first (${staging}) for: ${ACME_DOMAIN}, *.${ACME_DOMAIN}"
		if ! lego_run "${staging}" "${ACME_PATH}/staging" --no-random-sleep; then
			log "The staging server refused the certificate, so not asking the real one (see the messages above)"
			return 1
		fi
		settings_fingerprint > "${ACME_PATH}/staging.ok"
		log "The staging server worked - now the real certificate"
	fi
	log "Getting the certificate from ${ACME_SERVER} for: ${ACME_DOMAIN}, *.${ACME_DOMAIN}"
	# (a new certificate only if the current one is due or for other names - CAs limit duplicate certificates - but it is
	# always installed, e.g. after using an own certificate in between)
	lego_run "${ACME_SERVER}" "${ACME_PATH}/live" --no-random-sleep --force-cert-domains || return 1
	deploy
}

renew() {
	# Only for certificates the app got (not the user's own or the temporary one)
	load_settings > /dev/null 2>&1 || return 0
	[ "${ACME_ENABLED}" = yes ] || return 0
	if ! output="$(lego_run "${ACME_SERVER}" "${ACME_PATH}/live" --deploy-hook "${APP_PATH}/cert.sh deploy" 2>&1)"; then
		log "Renewing the certificate failed: $(echo "${output}" | tail -n 3)"
		if [ -x /usr/sbin/alert_test ]; then
			/usr/sbin/alert_test -a 1501 -p "<br><br><b>Nginx: renewing the certificate for ${ACME_DOMAIN} failed</b> - see the Nginx app's page" -f
		fi
		return 1
	fi
}

deploy() {
	cert="$(find "${ACME_PATH}/live" -name default.crt | head -n 1)"
	key="$(find "${ACME_PATH}/live" -name default.key | head -n 1)"
	if [ ! -s "${cert}" ] || [ ! -s "${key}" ]; then
		log "lego's certificate wasn't found in: ${ACME_PATH}/live"
		return 1
	fi
	cp "${key}" "${DATA_PATH}/certs/default.key.tmp" && chmod 600 "${DATA_PATH}/certs/default.key.tmp" \
		&& cp "${cert}" "${DATA_PATH}/certs/default.crt.tmp" \
		&& mv "${DATA_PATH}/certs/default.key.tmp" "${DATA_PATH}/certs/default.key" \
		&& mv "${DATA_PATH}/certs/default.crt.tmp" "${DATA_PATH}/certs/default.crt" \
		&& log "Installed the new certificate for: ${ACME_DOMAIN}"
	sh "${APP_PATH}/nginx_ctl.sh" reload
}

case "$1" in
	issue) issue ;;
	renew) renew ;;
	deploy) load_settings > /dev/null 2>&1; deploy ;;
	*) echo "Usage: $0 issue | renew | deploy"; exit 1 ;;
esac
