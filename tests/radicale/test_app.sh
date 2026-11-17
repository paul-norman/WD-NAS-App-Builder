#!/bin/sh
# Radicale from its package (tests/common/nas.sh), with the Nginx app (tests/radicale/with): its first start as its own
# user, only on the NAS itself, the Family collections, users from the page (their own collections and the Family
# links), phones' discovery, sharing the Family calendar and contacts but not users' own, passwords, a Family link put
# back, removing a user, its site through Nginx, the network setting, a restart keeping everything, removal
. /t/common/nas.sh radicale
# As WD's NAS has it: no group called nogroup - nobody's own group is the share users' (1000), which Nginx's workers
# then run as
sed -i '/^nogroup:/d' /etc/group; sed -i 's/^\(nobody:[^:]*:[0-9]*:\)[0-9]*:/\11000:/' /etc/passwd
DOMAIN=nas.example.test
U=http://127.0.0.1:5232
R=$D/collections/collection-root
# A DAV request as a user: dav <user:password> <method> <path> [curl options] - prints the status code (the body in /tmp/dav)
dav() { a=$1; m=$2; p=$3; shift 3; curl -s -o /tmp/dav -w '%{http_code}' -u "$a" -X "$m" "$@" "$U$p"; }
site() { p=$1; shift; curl -sk -m 10 --resolve "calendar.$DOMAIN:443:127.0.0.1" "$@" "https://calendar.$DOMAIN$p"; }
event() { printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//test//EN\r\nBEGIN:VEVENT\r\nUID:%s\r\nDTSTAMP:20261117T100000Z\r\nDTSTART:20261120T180000Z\r\nSUMMARY:%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' "$1" "$2" > /tmp/event.ics; }

echo '== with Nginx'
install_app nginx
wait_port 443 30 && pass 'Nginx answering' || { fail "Nginx: $(tail -n 5 /tmp/start.log)"; exit 1; }
php -r '$f=$argv[1]; $s=json_decode(file_get_contents($f),true); $s["domain"]=$argv[2]; file_put_contents($f, json_encode($s));' $P/_nginx/apps.json $DOMAIN

echo '== first start'
install_app
wait_port 5232 120 && pass 'answering on 5232' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 5 $D/radicale.out)"; exit 1; }
PID=$(cat /var/run/radicale.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 53 ] && [ "$(stat -c '%U %a' $D/collections)" = 'radicale 700' ] && [ "$(stat -c '%U %G %a' $D/users)" = 'root radicale 640' ] && [ "$(stat -c '%a' $D)" = 711 ] \
    && pass "runs as its own user (53), its collections its own; the users file root's, readable by Radicale" || fail "users: $(stat -c '%n %U %G %a' $D $D/collections $D/users)"
awk 'NR > 1 && $4 == "0A" && index($2, ":1470") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1), the Nginx app being there'
grep -q VCALENDAR $R/family/calendar/.Radicale.props && grep -q VADDRESSBOOK $R/family/contacts/.Radicale.props && [ ! -s $D/users ] \
    && pass 'the Family calendar and contacts made; no users yet' || fail "family: $(ls -la $R/family; cat $D/users)"
[ "$(dav nobody:nothing-here-1 PROPFIND / -H 'Depth: 0')" = 401 ] && pass 'nobody can log in without a user from the page (401)' || fail "no users: $(cat /tmp/dav)"

echo '== its page: users'
page_up radicale
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"3.9.2"' ] && [ "$(echo "$ST" | j '$d["users"]')" = '[]' ] \
    && [ "$(echo "$ST" | j '$d["site"]["url"]')" = "\"https://calendar.$DOMAIN/\"" ] \
    && pass "the page: Radicale 3.9.2 answering, no users, its address https://calendar.$DOMAIN/" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post add_user -d name=family | j '$d["ok"]')" = false ] && [ "$(post add_user -d name=Bad/Name | j '$d["ok"]')" = false ] \
    && [ "$(post add_user -d name=alice -d password=short | j '$d["ok"]')" = false ] \
    && pass 'refused: the name family, a bad name, a short password' || fail 'bad user accepted'
AL=$(post add_user -d name=alice -d password=Alice.Password-1)
BP=$(post add_user -d name=bob | j '$d["password"]' | tr -d '"')
A=alice:Alice.Password-1; B="bob:$BP"
[ "$(echo "$AL" | j '$d["password"]')" = '"Alice.Password-1"' ] && [ ${#BP} = 20 ] && grep -q '^alice:\$6\$rounds=5000\$' $D/users && ! grep -q Alice.Password $D/users \
    && [ "$(get status | j '$d["users"]')" = '["alice","bob"]' ] && [ "$(stat -c '%U %G %a' $D/users)" = 'root radicale 640' ] \
    && pass 'alice (her password) and bob (a generated one) added: only SHA-512 hashes kept' || fail "add: $AL $(cat $D/users)"
[ "$(post add_user -d name=alice | j '$d["ok"]')" = false ] && pass 'the same name twice refused' || fail 'duplicate accepted'
[ "$(stat -c %U $R/alice)" = radicale ] && grep -q '"Calendar"' $R/alice/calendar/.Radicale.props && grep -q '"Contacts"' $R/alice/contacts/.Radicale.props \
    && [ "$(readlink $R/bob/family-calendar)" = ../family/calendar ] && [ "$(readlink $R/bob/family-contacts)" = ../family/contacts ] \
    && pass "each user's folder: their own calendar and contacts, links to the Family ones" || fail "folders: $(ls -la $R/alice $R/bob)"

echo '== phones'
W=$(code -o /dev/null -w '%{http_code} %{redirect_url}' $U/.well-known/caldav)
echo "$W" | grep -q '^30[1-8] ' && pass "phones' discovery: /.well-known/caldav redirects ($W)" || fail "well-known: $W"
[ "$(dav "$A" PROPFIND /alice/ -H 'Depth: 1')" = 207 ] && grep -q '/alice/calendar/' /tmp/dav && grep -q '/alice/contacts/' /tmp/dav \
    && grep -q '/alice/family-calendar/' /tmp/dav && grep -q '/alice/family-contacts/' /tmp/dav \
    && pass "alice's folder lists her calendar and contacts and the Family ones (what phones find)" || fail "propfind: $(head -c 300 /tmp/dav)"
[ "$(dav "$A" PROPFIND /alice/ -H 'Depth: 0' -u alice:Wrong.Password-1)" = 401 ] && pass 'a wrong password refused (401)' || fail 'wrong password accepted'

echo '== sharing'
event fam1 'Family dinner'
C1=$(dav "$A" PUT /alice/family-calendar/fam1.ics --data-binary @/tmp/event.ics -H 'Content-Type: text/calendar')
event own1 'Alice only'
C2=$(dav "$A" PUT /alice/calendar/own1.ics --data-binary @/tmp/event.ics -H 'Content-Type: text/calendar')
[ "$C1" = 201 ] && [ "$C2" = 201 ] && [ "$(dav "$B" GET /bob/family-calendar/fam1.ics)" = 200 ] && grep -q 'SUMMARY:Family dinner' /tmp/dav \
    && [ -f $R/family/calendar/fam1.ics ] && pass "alice's Family event seen by bob (kept once, in family/)" || fail "family event: $C1 $C2 $(cat /tmp/dav)"
[ "$(dav "$B" GET /alice/calendar/own1.ics)" = 403 ] && [ "$(dav "$B" PROPFIND /alice/calendar/ -H 'Depth: 1')" = 403 ] \
    && pass "alice's own calendar refused to bob (403)" || fail "own calendar: $(cat /tmp/dav)"
printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:gran\r\nFN:Gran\r\nN:;Gran;;;\r\nTEL:+441234567890\r\nEND:VCARD\r\n' > /tmp/gran.vcf
[ "$(dav "$B" PUT /bob/family-contacts/gran.vcf --data-binary @/tmp/gran.vcf -H 'Content-Type: text/vcard')" = 201 ] \
    && [ "$(dav "$A" GET /alice/family-contacts/gran.vcf)" = 200 ] && grep -q 'FN:Gran' /tmp/dav \
    && pass "bob's Family contact seen by alice" || fail "family contact: $(cat /tmp/dav)"

echo '== a phone removing the Family calendar'
[ "$(dav "$B" DELETE /bob/family-calendar/)" = 200 ] && [ ! -e $R/bob/family-calendar ] && [ -f $R/family/calendar/fam1.ics ] \
    && pass "only bob's link removed, the Family calendar kept" || fail "delete: $(ls -la $R/bob $R/family/calendar)"
sh $P/radicale/radicale_ctl.sh daily > /dev/null 2>&1
[ "$(dav "$B" GET /bob/family-calendar/fam1.ics)" = 200 ] && pass 'put back by the daily job' || fail "not put back: $(ls -la $R/bob)"

echo '== passwords'
NP=$(post new_password -d name=bob -d password=Bob.New-Password1 | j '$d["password"]')
[ "$NP" = '"Bob.New-Password1"' ] && [ "$(dav bob:Bob.New-Password1 PROPFIND /bob/ -H 'Depth: 0')" = 207 ] && [ "$(dav "$B" PROPFIND /bob/ -H 'Depth: 0')" = 401 ] \
    && pass 'a new password for bob (no restart): the old one refused' || fail "new password: $NP"
B=bob:Bob.New-Password1

echo '== removing a user'
# (Radicale remembers a successful login for 15 seconds)
RM=$(post remove_user -d name=bob | j '$d["ok"]'); sleep 16
[ "$RM" = true ] && [ "$(dav "$B" PROPFIND /bob/ -H 'Depth: 0')" = 401 ] && [ -d $R/bob ] \
    && [ "$(get status | j '$d["users"]')" = '["alice"]' ] && [ "$(dav "$A" GET /alice/family-contacts/gran.vcf)" = 200 ] \
    && pass "bob removed: refused, his folder kept, the Family contact he added still there" || fail "remove: $(cat $D/users)"
[ "$(post remove_user -d name=nobody | j '$d["ok"]')" = false ] && pass 'removing an unknown user refused' || fail 'unknown user removed'

echo '== its site, through Nginx'
grep -q 'proxy_pass *http://127.0.0.1:5232' $P/_nginx/sites/60-app-calendar.conf 2>/dev/null && grep -q 'client_max_body_size' $P/_nginx/sites/60-app-calendar.conf \
    && [ "$(site /alice/ -o /dev/null -w '%{http_code}' -u "$A" -X PROPFIND -H 'Depth: 1')" = 207 ] && site /.web/ | grep -q Radicale \
    && pass "its site https://calendar.$DOMAIN/ (uploads allowed): alice's calendars and the web page" || fail "site: $(ls $P/_nginx/sites; site /.web/ | head -c 200)"

echo '== on the network'
RS=$(post listen -d listen=all)
[ "$(echo "$RS" | j '$d["ok"]')" = true ] && grep -q '^hosts = 0.0.0.0:5232' $D/config && awk 'NR > 1 && $4 == "0A" && index($2, ":1470") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && pass 'on the network too (0.0.0.0:5232)' || fail "listen all: $RS $(grep hosts $D/config)"
post listen -d listen=local > /dev/null
grep -q '^hosts = 127.0.0.1:5232' $D/config && pass 'and back to the NAS only' || fail "listen local: $(grep hosts $D/config)"

echo '== restart'
sh $P/radicale/stop.sh $P/radicale > /dev/null 2>&1
listening 5232 && fail 'still answering once stopped' || true
sh $P/radicale/start.sh $P/radicale > /tmp/start.log 2>&1
wait_port 5232 60 && [ "$(dav "$A" GET /alice/calendar/own1.ics)" = 200 ] && [ "$(dav "$A" GET /alice/family-calendar/fam1.ics)" = 200 ] \
    && pass "restarted: alice's events kept, the same login" || fail "restart: $(tail -n 5 /tmp/start.log)"
grep -E '\[(ERROR|CRITICAL)\]' $D/radicale.out | head -3

echo '== removal'
finish_app
! grep -q radicale-daily /var/spool/cron/crontabs/root && [ -f $R/family/calendar/fam1.ics ] && [ -s $D/users ] \
    && pass 'its cron line gone; its calendars and users kept' || fail 'removal'
