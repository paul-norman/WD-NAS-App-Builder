#!/bin/sh
# Forgejo from its package (tests/common/nas.sh): its admin user (generated password), sign-in required and no sign-ups,
# a private repository pushed to and cloned with the app's own Git over HTTP, SSH switched on, a backup made from its
# page, a new password, where it listens, stopping and removal
. /t/common/nas.sh forgejo
U=http://127.0.0.1:3002

echo '== first start'
install_app
wait_port 3002 120 && pass 'answering on 3002' || { fail "not answering: $(tail -n 10 /tmp/start.log $D/forgejo.log 2>/dev/null)"; exit 1; }
page_up

for i in $(seq 1 30); do [ "$(get status | j '$d["answering"]')" = true ] && break; sleep 2; done
PW=$(post password -d show=1 | j '$d["password"]' | tr -d '"')
api() { curl -s -u "nas-admin:$PW" -H 'Content-Type: application/json' "$@"; }
[ "$(api $U/api/v1/user | j '$d["login"]')" = '"nas-admin"' ] && [ "$(api $U/api/v1/user | j '$d["is_admin"]')" = true ] \
    && pass "its admin user (nas-admin - admin is reserved) logs in with the page's password" || fail "admin: $(api $U/api/v1/user | head -c 200)"
# Its sign-up page says registration is disabled - with a 200 - rather than being missing
[ "$(code $U/explore/repos)" = 303 ] && curl -s $U/user/sign_up | grep -qi 'registration is disabled' && [ "$(api "$U/api/v1/admin/users" | j 'count($d)')" = 1 ] \
    && pass 'sign-in required to see anything, no sign-ups (the admin is the only user)' || fail "public: explore $(code $U/explore/repos), sign-up page: $(curl -s $U/user/sign_up | grep -io 'registration[^<]*' | head -n 1)"

echo "== a repository, with the app's Git"
api -X POST -d '{"name":"notes","private":true,"auto_init":true,"default_branch":"main"}' $U/api/v1/user/repos > /tmp/repo.json
G=$P/forgejo/binaries/git/bin/git
[ -x $G ] || G=$(find $P/forgejo/binaries -name git -type f -perm -u+x | head -n 1)
cd /tmp && HOME=/tmp $G clone -q "http://nas-admin:$PW@127.0.0.1:3002/nas-admin/notes.git" notes 2> /tmp/clone.log \
    && cd /tmp/notes && echo 'hello from the NAS' > hello.txt && HOME=/tmp $G -c user.name=Test -c user.email=t@example.test add hello.txt \
    && HOME=/tmp $G -c user.name=Test -c user.email=t@example.test commit -qm 'A note' && HOME=/tmp $G push -q origin main 2> /tmp/push.log \
    && cd /tmp && HOME=/tmp $G clone -q "http://nas-admin:$PW@127.0.0.1:3002/nas-admin/notes.git" notes2 && [ "$(cat /tmp/notes2/hello.txt)" = 'hello from the NAS' ] \
    && pass "a private repository: cloned, pushed to and cloned again with the app's Git ($($G --version))" || fail "git: $(cat /tmp/clone.log /tmp/push.log | tail -n 5)"
cd /
[ "$(code "$U/nas-admin/notes")" != 200 ] && [ "$(get status | j '$d["repositories"]')" = 1 ] && pass '...not visible without signing in; the page counts it' || fail 'private repo visible'

echo '== SSH, a backup, a new password, where it listens'
post settings -d listen=all -d ssh=1 -d backup=weekly -d backup_keep=4 > /dev/null
wait_port 2222 60 && [ "$(get status | j '$d["ssh_url"]')" != '""' ] && pass "SSH on 2222: $(get status | j '$d["ssh_url"]')" || fail "ssh: $(get status | j '$d["ssh_url"]')"
post backup -d confirm=1 > /dev/null

for i in $(seq 1 60); do [ "$(get status | j 'count($d["backups"])')" = 1 ] && [ "$(get status | j '$d["backup_running"]')" = false ] && break; sleep 2; done
B=$(get status | j '$d["backups"][0]["name"]' | tr -d '"')
echo "$B" | grep -q 'tar.gz' && tar -tzf "$(get status | j '$d["backup_dir"]' | tr -d '"')/$B" | grep -q "forgejo-db\|repos/" && pass "a backup from the page: $B (database and repositories)" || fail "backup: $(get status | j '$d["backups"]')"
post settings -d listen=all -d ssh=1 -d backup=daily -d backup_keep=0 | grep -q 'Keep 1-30' && pass 'a bad number of backups to keep refused' || fail 'keep check'
NEW=$(post new_password -d confirm=1 | j '$d["password"]' | tr -d '"')
[ "$NEW" != "$PW" ] && [ "$(code -u "nas-admin:$NEW" $U/api/v1/user)" = 200 ] && [ "$(code -u "nas-admin:$PW" $U/api/v1/user)" = 401 ] && pass "a new password works, the old one doesn't" || fail 'new password'
post settings -d listen=local -d ssh=0 -d backup=weekly -d backup_keep=4 > /dev/null; wait_port 3002 60; sleep 2
grep -q '^HTTP_ADDR *= *127.0.0.1' $D/custom/conf/app.ini 2>/dev/null || grep -rq '^HTTP_ADDR *= *127.0.0.1' $D 2>/dev/null
[ $? = 0 ] && ! listening 2222 && pass 'only through the Nginx app (127.0.0.1), SSH off' || fail "listen: $(grep -r 'HTTP_ADDR' $D 2>/dev/null | head -n 2)"

echo '== removed'
finish_app
