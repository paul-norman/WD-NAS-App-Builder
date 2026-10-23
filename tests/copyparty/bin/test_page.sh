#!/bin/sh
# The management page's API (on this image's PHP), as the dashboard calls it - with an admin's WD session and the page's
# CSRF token - against a running copyparty
A=/mnt/HD/HD_a2/Nas_Prog/copyparty; D=/mnt/HD/HD_a2/Nas_Prog/_copyparty; P=/mnt/HD/HD_a2/Public
. /t/bin/setup.sh
mkdir -p /var/www/apps && ln -s $A/manage /var/www/apps/copyparty
echo "PHP $(php -r 'echo PHP_VERSION;')"
sh $A/cpp_ctl.sh start > /dev/null 2>&1
echo "administrators:x:1001:admin" >> /etc/group; mkdir -p /tmp/sess; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &
sleep 1
B=http://127.0.0.1:8080/apps/copyparty; CK='Cookie: PHPSESSID=adminsession123'; U=http://127.0.0.1:3923
T=$(curl -s -H "$CK" $B/index.php | sed -n 's/.*var csrf = "\([^"]*\)".*/\1/p')
get() { curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' "$B/api.php?action=$1"; }
post() { a=$1; shift; curl -s -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $T" -X POST "$@" "$B/api.php?action=$a"; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# Who copyparty took a login for ("*": no one - a wrong password isn't refused where everyone may look, it's just ignored)
who() { curl -s -A 'Mozilla/5.0' -u "$1" "$U/?ls" | sed -n 's/.*"acct": "\([^"]*\)".*/\1/p'; }
folder() { post save_folder --data-urlencode "name=$1" --data-urlencode "path=$2" --data-urlencode "access=$3" ${4:+--data-urlencode "old_name=$4"}; }

ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["users"]')" = '["admin"]' ] && [ "$(echo "$ST" | j '$d["folders"][0]["can"]')" = '"write"' ] \
	&& pass "status: running $(echo "$ST" | j '$d["version"]'), users $(echo "$ST" | j '$d["users"]'), folders $(echo "$ST" | j '$d["folders"]')" || fail "status: $(echo "$ST" | cut -c1-300)"
[ "$(code -H 'X-Requested-With: XMLHttpRequest' $B/api.php?action=status)" = 403 ] && pass "without a NAS login: refused" || fail "no session allowed"
[ "$(code -H "$CK" -H 'X-Requested-With: XMLHttpRequest' -H 'X-CSRF-Token: wrong' -X POST -d name=admin "$B/api.php?action=password")" = 403 ] && pass "a wrong CSRF token: refused" || fail "csrf"
PW=$(post password -d name=admin | j '$d["password"]' | tr -d '"')
[ "$(code -u admin:$PW $U/public/?ls)" = 200 ] && pass "admin's password shown (and it works)" || fail "password: $PW"

echo "== users"
R=$(post add_user -d name=bob); BOB=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ ${#BOB} = 20 ] && [ "$(who bob:$BOB)" = bob ] && [ "$(code -u bob:$BOB $U/public/?ls)" = 403 ] && pass "a user added: logs in, but no folder yet" || fail "add user: $R"
post add_user -d name=bob | grep -q "already" && post add_user --data-urlencode 'name=a b' | grep -q "User names" && pass "a duplicate or invalid user name refused" || fail "user name checks"
R=$(post new_password -d name=bob); BOB2=$(echo "$R" | j '$d["password"]' | tr -d '"')
[ "$(who bob:$BOB2)" = bob ] && [ "$(who bob:$BOB)" = "*" ] && pass "a new password works, the old one doesn't" || fail "new password: $R"

echo "== folders"
mkdir -p "$P/Photos" && chmod 777 "$P/Photos" && echo pic > "$P/Photos/p.txt"
R=$(folder photos "$P/Photos" '{"bob":"read","admin":"admin","*":"none"}')
[ "$(curl -s -u bob:$BOB2 $U/photos/p.txt)" = pic ] && [ "$(code $U/photos/p.txt)" != 200 ] && pass "a folder shared with bob (view), not with everyone" || fail "share: $R"
folder photos "$P/Photos" '{"bob":"write"}' photos > /dev/null
[ "$(code -u bob:$BOB2 -T /etc/hostname $U/photos/up.txt)" = 201 ] && pass "changed to view and upload: bob can upload" || fail "change"
folder pics "$P/Photos" '{"bob":"read"}' photos > /dev/null
[ "$(code -u bob:$BOB2 $U/pics/p.txt)" = 200 ] && [ "$(code -u bob:$BOB2 $U/photos/p.txt)" != 200 ] && pass "renamed: its new address works, the old one doesn't" || fail "rename"
for bad in "/mnt/HD/HD_a2/Nas_Prog/_copyparty" /etc "/mnt/HD/HD_a2/../../etc" "$P/missing"; do
	R=$(folder x "$bad" '{"admin":"read"}')
	[ "$(echo "$R" | j '$d["ok"]')" = false ] && pass "refused: $bad ($(echo "$R" | j '$d["error"]'))" || fail "allowed: $bad"
done
ln -s /mnt/HD/HD_a2/Nas_Prog "$P/apps"
folder x "$P/apps" '{"admin":"read"}' | grep -q "apps' own files" && pass "refused: a link to Nas_Prog" || fail "link to Nas_Prog allowed"
folder x "$P" '{"*":"full"}' | grep -q "Unknown access" && folder public "$P/Photos" '{"admin":"read"}' | grep -q "already called" \
	&& folder 'Bad Name' "$P" '{}' | grep -q "Folder names" && pass "refused: full access for everyone, a name in use, an invalid name" || fail "folder checks"
mkdir -p "$P/Locked" && chmod 755 "$P/Locked"
folder locked "$P/Locked" '{"admin":"full"}' > /dev/null
[ "$(get status | j '$d["folders"][2]["can"]')" = '"read"' ] && pass "a folder copyparty can only read is flagged" || fail "read-only flag: $(get status | j '$d["folders"]')"

echo "== removing"
post remove_user -d name=bob > /dev/null
[ "$(who bob:$BOB2)" = "*" ] && ! grep -q '"bob"' $D/settings.json && pass "a user removed (and from every folder)" || fail "remove user"
post remove_user -d name=admin | grep -q "at least one" && pass "the last user can't be removed" || fail "last user removed"
post remove_folder -d name=locked > /dev/null
[ "$(code -u admin:$PW $U/locked/)" != 200 ] && pass "a folder no longer shared" || fail "remove folder"

echo "== settings"
post settings -d listen=local -d sftp=1 -d tags=0 > /dev/null
grep -q 'i: 127.0.0.1' $D/config/copyparty.conf && grep -q 'sftp-i: 127.0.0.1' $D/config/copyparty.conf && [ "$(code -u admin:$PW $U/)" = 200 ] \
	&& pass "only through the Nginx app: on 127.0.0.1 (SFTP too)" || fail "listen: $(grep -E '^  (i|sftp)' $D/config/copyparty.conf)"
post settings -d listen=all -d sftp=0 -d tags=0 > /dev/null
grep -q 'i: 0.0.0.0' $D/config/copyparty.conf && ! grep -q 'sftp' $D/config/copyparty.conf && pass "back to the network, SFTP off" || fail "settings"
post restart -d confirm=1 > /dev/null
[ "$(get status | j '$d["answering"]')" = true ] && pass "restarted" || fail "restart"
