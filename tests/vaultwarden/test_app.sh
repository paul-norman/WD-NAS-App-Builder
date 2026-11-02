#!/bin/sh
# Vaultwarden from its package (tests/common/nas.sh): on the NAS itself only (for the Nginx app), its web vault, the
# admin panel with the page's generated token (only its hash in Vaultwarden's settings), sign-ups (on at first, for the
# first accounts; off and on again from the page), backups (a consistent copy of the database, where the page says,
# keeping the number it says), a new token, stopping and removal
. /t/common/nas.sh vaultwarden
U=http://127.0.0.1:8222

echo '== first start'
install_app
wait_port 8222 60 && pass 'answering on 8222' || { fail "not answering: $(tail -n 10 /tmp/start.log $D/vaultwarden.log)"; exit 1; }
[ -z "$(awk 'NR > 1 { split($2, l, ":"); if (l[2] == "201E" && $4 == "0A" && l[1] != "0100007F") print }' /proc/net/tcp)" ] \
    && pass "only on 127.0.0.1 (reached through the Nginx app's HTTPS - a password vault never on plain HTTP)" || fail 'listening on the network'
curl -s $U/ | grep -qi "vaultwarden\|bitwarden" && [ "$(code $U/alive)" = 200 ] && pass 'its web vault and /alive' || fail 'web vault'
page_up
TOKEN=$(post token -d show=1 | j '$d["token"]' | tr -d '"')
admin() { curl -s -o /dev/null -w '%{http_code}' -c /tmp/vwc -b /tmp/vwc --data-urlencode "token=$1" $U/admin; }
# The right token: its admin page - 200; a wrong one: 401
[ ${#TOKEN} -ge 32 ] && [ "$(admin "$TOKEN")" = 200 ] && [ "$(admin wrong-token)" = 401 ] && pass "the admin panel: the page's token, not another" || fail "admin: $(admin "$TOKEN") $(admin wrong)"
grep -q "ADMIN_TOKEN='\$argon2id" $D/vaultwarden.env && ! grep -q "$TOKEN" $D/vaultwarden.env && [ "$(stat -c '%U %a' $D/admin_token)" = 'root 600' ] \
    && pass "Vaultwarden gets only the token's argon2 hash; the token itself is root's only" || fail "token storage: $(grep ADMIN_TOKEN $D/vaultwarden.env | cut -c1-40)"

echo '== sign-ups'
reg() { curl -s -H 'Content-Type: application/json' -d '{"email":"test@example.test","name":"Test"}' $U/identity/accounts/register/send-verification-email; }
# On at first, for the family's accounts - the README's next step is turning them off on the page
[ "$(get status | j '$d["signups"]')" = true ] && ! reg | grep -qi "not allowed\|disabled" && pass 'sign-ups on at first (to create the accounts): registration accepted' || fail "sign-ups at first: $(reg | head -c 200)"
post signups > /dev/null; wait_port 8222 30; sleep 2
[ "$(get status | j '$d["signups"]')" = false ] && reg | grep -qi "not allowed\|disabled" && pass "turned off from the page (restarted): $(reg | grep -o '"message":"[^"]*' | head -n 1 | cut -c12-70)" || fail "sign-ups still on: $(reg | head -c 200)"
post signups -d on=1 > /dev/null; wait_port 8222 30; sleep 2
! reg | grep -qi "not allowed\|disabled" && pass '...and on again' || fail 'sign-ups still off'

echo '== backups'
mkdir -p $V/Public/Backups
post backup_settings -d dir=/etc -d keep=7 | grep -q "NAS's volumes" && post backup_settings -d dir=$V/Public/Backups/x -d keep=0 | grep -q 'between 1 and 365' \
    && post backup_settings -d dir=$V/Public/missing/deeper -d keep=7 | grep -q 'No such folder' && pass "refused: a folder off the NAS's volumes, 0 to keep, a folder with no parent" || fail 'backup checks'
post backup_settings -d dir=$V/Public/Backups/Vaultwarden -d keep=2 > /dev/null

for i in 1 2 3; do post backup_now -d confirm=1 > /tmp/b$i.json; sleep 1.2; done
N=$(ls $V/Public/Backups/Vaultwarden/*.tar.gz 2>/dev/null | wc -l); F=$(ls -t $V/Public/Backups/Vaultwarden/*.tar.gz | head -n 1)
tar -xzf "$F" -C /tmp 2>/dev/null; DB=$(find /tmp -name db.sqlite3 -newer /tmp/b1.json | head -n 1)
[ "$N" = 2 ] && [ -n "$DB" ] && [ "$(sqlite3 "$DB" 'PRAGMA integrity_check' 2>/dev/null || $P/vaultwarden/binaries/sqlite3 "$DB" 'PRAGMA integrity_check')" = ok ] && [ "$(stat -c %a "$F")" = 600 ] \
    && pass "backups where the page says, 2 kept of 3 made, each a sound copy of the database ($(tar -tzf "$F" | tr '\n' ' ' | cut -c1-80)) - root's only" || fail "backups: $N files; $(cat /tmp/b3.json)"

echo '== a new token'
NEW=$(post new_token -d confirm=1 | j '$d["token"]' | tr -d '"'); wait_port 8222 30; sleep 2; rm -f /tmp/vwc
[ "$NEW" != "$TOKEN" ] && [ "$(admin "$NEW")" = 200 ] && [ "$(admin "$TOKEN")" = 401 ] && pass "a new admin token works, the old one doesn't" || fail 'new token'

echo '== removed'
finish_app
