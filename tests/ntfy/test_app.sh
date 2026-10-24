#!/bin/sh
# ntfy from its package (tests/common/nas.sh): deny-all access (nothing without the app's login or token), a phone's
# subscription receiving the page's test notification as it's sent, new passwords and tokens, settings (where it listens,
# the iPhone relay), stopping and removal
. /t/common/nas.sh ntfy
U=http://127.0.0.1:2586

echo "== first start"
install_app
wait_port 2586 60 && pass "answering on 2586" || { fail "not answering: $(tail -n 10 /tmp/start.log)"; exit 1; }
page_up
PW=$(post password -d show=1 | j '$d["password"]' | tr -d '"'); TK=$(post token -d show=1 | j '$d["token"]' | tr -d '"')
echo "$TK" | grep -qE '^tk_[a-z0-9]{29}$' && [ ${#PW} -ge 16 ] && pass "a generated password (for the phone app) and token (for the NAS's apps): $(echo "$TK" | cut -c1-6)..." || fail "secrets: $PW $TK"
[ "$(code -X POST -d hi $U/alerts)" = 403 ] && [ "$(code $U/alerts/json?poll=1)" = 403 ] && pass "deny-all: no publishing or reading without a login" || fail "anonymous allowed"
[ "$(code -u admin:$PW -X POST -d hi $U/alerts)" = 200 ] && [ "$(code -H "Authorization: Bearer $TK" -X POST -d hi $U/alerts)" = 200 ] \
	&& [ "$(code -u admin:wrong -X POST -d hi $U/alerts)" = 401 ] && pass "the password and the token publish; a wrong password doesn't" || fail "auth"
! grep -q "$PW" $D/data/server.yml 2>/dev/null && grep -q '^auth-default-access: "deny-all"\|^auth-default-access: deny-all' $D/data/server.yml \
	&& [ "$(stat -c '%a' $D/data/server.yml)" = 600 ] && pass "its configuration: deny-all, the password only as a hash (its user's only)" || fail "config: $(grep -E 'auth-' $D/data/server.yml | head -n 4)"

echo "== a phone's subscription"
(curl -s -N -H "Authorization: Bearer $TK" "$U/phone/json" > /tmp/stream &) ; sleep 2
R=$(post test -d topic=phone)
sleep 2
[ "$(echo "$R" | j '$d["ok"]')" = true ] && grep -q '"message":"Test notification from the NAS' /tmp/stream && grep -q '"title":"Hello from the NAS"' /tmp/stream \
	&& pass "the page's test notification reaches a subscriber as it's sent" || fail "subscription: $R $(cat /tmp/stream | head -c 300)"
post test -d 'topic=bad topic!' | grep -q "Topics are" && pass "a bad topic name refused" || fail "topic check"

echo "== new password and token"
NP=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"'); NT=$(post new_token -d confirm=1 | j '$d["token"]' | tr -d '"'); wait_port 2586 30; sleep 1
[ "$(code -u admin:$NP -X POST -d hi $U/alerts)" = 200 ] && [ "$(code -u admin:$PW -X POST -d hi $U/alerts)" = 401 ] \
	&& [ "$(code -H "Authorization: Bearer $NT" -X POST -d hi $U/alerts)" = 200 ] && [ "$(code -H "Authorization: Bearer $TK" -X POST -d hi $U/alerts)" = 401 ] \
	&& pass "new ones work, the old ones don't" || fail "new secrets"

echo "== settings"
post settings -d listen=local -d ios_push=1 > /dev/null; wait_port 2586 30; sleep 1
grep -q 'listen-http: "127.0.0.1:2586"\|listen-http: 127.0.0.1:2586' $D/data/server.yml && grep -q "upstream-base-url.*https://ntfy.sh" $D/data/server.yml \
	&& [ "$(get status | j '$d["answering"]')" = true ] && pass "only through the Nginx app (127.0.0.1), the iPhone relay on" || fail "settings: $(grep -E 'listen|upstream' $D/data/server.yml)"
post settings -d listen=all -d ios_push=0 > /dev/null; wait_port 2586 30
! grep -q "upstream-base-url" $D/data/server.yml && pass "...and off again" || fail "relay still on"

echo "== removed"
finish_app
