#!/bin/sh
# The OpenSSH app from its package (tests/common/nas.sh), on a stand-in for WD's own SSH server (wd.sh: OpenSSH 8.4p1
# set out as WD has it): 10.6 swapped in underneath WD's ssh_daemon after a trial login, an open session kept, the same
# logins (the user's key, the password, root refused), SFTP, keys from the page, password logins off, falling back to
# WD's sshd when the app's can't take over, no seccomp filters, a reboot, switching back, removal
. /t/common/nas.sh openssh
sh /t/app/wd.sh
NEW=/client/new_ed25519
O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5 -o LogLevel=ERROR"
# A command over SSH with a key, as the user's computer (Debian's ssh client): key_login <key> <user> <command>
key_login() { ssh $O -i "$1" "$2@127.0.0.1" "$3" 2>&1; }
# A password login: pw_login <user> <password>
pw_login() {
	printf '#!/bin/sh\necho "%s"\n' "$2" > /tmp/askpass; chmod 755 /tmp/askpass
	SSH_ASKPASS=/tmp/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=x ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=5 -o LogLevel=ERROR "$1@127.0.0.1" 'echo logged-in' 2>&1
}
# The version answering on port 22
server() { ssh -v $O -o PreferredAuthentications=none nobody@127.0.0.1 true 2>&1 | tr -d '\r' | sed -n 's/.*remote software version \([^ ]*\).*/\1/p'; }
# Waits for the version given on port 22
wait_server() { i=0; until [ "$(server)" = "$1" ] || [ $i -ge ${2:-20} ]; do sleep 1; i=$((i + 1)); done; [ "$(server)" = "$1" ]; }
listener() { for d in /proc/[0-9]*; do tr '\0' ' ' < $d/cmdline 2>/dev/null | grep -q "\[listener\]" && readlink $d/exe && return; done; }
ssh-keygen -q -t ed25519 -N '' -C 'laptop' -f $NEW

echo "== WD's sshd (before)"
wait_server OpenSSH_8.4p1 && [ "$(key_login /client/old_rsa sshd 'id -u')" = 0 ] && key_login /client/old_rsa root true | grep -q "denied" \
	&& [ "$(pw_login sshd Wd-Passw0rd)" = logged-in ] && pass "the stand-in NAS runs WD's OpenSSH 8.4p1: sshd logs in (key or password, with root's ID), root doesn't" \
	|| { fail "stand-in: $(server) $(key_login /client/old_rsa sshd 'id -u') $(tail -n 3 /var/log/sshd.log)"; exit 1; }
# (a session open before the switch, as the user's own over SSH - it must survive it)
(ssh $O -i /client/old_rsa sshd@127.0.0.1 'sleep 25; echo still-connected' > /tmp/session.out 2>&1 &)
sleep 2

echo "== switched to 10.6"
install_app
wait_server OpenSSH_10.6 && pass "OpenSSH 10.6 answers on port 22" || fail "not switched: $(server) $(tail -n 6 /tmp/debug_apkg)"
[ "$(readlink /usr/sbin/sshd)" = /usr/local/openssh/sshd ] && [ "$(readlink /usr/bin/sftp-server)" = /usr/local/openssh/libexec/sftp-server ] \
	&& [ "$(listener)" = "$(readlink -f $P/openssh/binaries/bin/sshd)" ] && grep -q "trial" /tmp/debug_apkg -v && ! grep -q "trial login .* failed" /tmp/debug_apkg \
	&& pass "WD's links point at the app's sshd and sftp-server; its listener is the app's (after a trial login)" || fail "links: $(readlink /usr/sbin/sshd) $(listener)"
ps -ef | grep -v grep | grep -q "openssh-trial" && fail "the trial sshd is still running" || pass "the trial sshd is gone"
[ "$(key_login /client/old_rsa sshd 'id -u')" = 0 ] && [ "$(pw_login sshd Wd-Passw0rd)" = logged-in ] && key_login /client/old_rsa root true | grep -q "denied" \
	&& [ "$(pw_login sshd wrong)" != logged-in ] && pass "the same logins: the user's key and WD's password (MD5, no salt) as sshd; root refused" \
	|| fail "logins: $(key_login /client/old_rsa sshd 'id -u') / $(pw_login sshd Wd-Passw0rd) $(tail -n 3 /var/log/sshd.log)"
OLDKEX=$(ssh -v $O -i /client/old_rsa sshd@127.0.0.1 true 2>&1 | tr -d '\r' | sed -n 's/.*kex: algorithm: //p' | head -n 1)
NEWKEX=$($P/openssh/binaries/bin/ssh -F /dev/null -v $O -i /client/old_rsa sshd@127.0.0.1 true 2>&1 | tr -d "\r" | sed -n 's/.*kex: algorithm: //p' | head -n 1)
[ -n "$OLDKEX" ] && [ "$NEWKEX" = mlkem768x25519-sha256 ] \
	&& pass "older clients still connect ($OLDKEX); new ones get post-quantum key exchange ($NEWKEX)" || fail "key exchange: old '$OLDKEX', new '$NEWKEX'"
# (OpenSSH 9.8+ refuses addresses that keep failing to log in for a while: not the NAS itself - the checks above were
# all from 127.0.0.1 - but another computer's)
IP=$(ip -4 addr show eth0 | awk '/inet / { split($2, a, "/"); print a[1] }')
for i in 1 2 3 4 5 6 7 8; do ssh $O -i /client/old_rsa "root@$IP" true > /dev/null 2>&1; done
ssh $O -i /client/old_rsa "sshd@$IP" 'echo in' 2>&1 | grep -q "in$" && fail "no penalty for $IP" \
	|| pass "an address that keeps failing is refused for a while ($IP); the NAS's own connections never are"
sleep 25
grep -q still-connected /tmp/session.out && pass "a session open during the switch stayed connected" || fail "the open session: $(cat /tmp/session.out)"
mkdir -p /mnt/HD/HD_a2/Public && echo "a file from the laptop" > /tmp/up.txt
printf 'put /tmp/up.txt /mnt/HD/HD_a2/Public/up.txt\nget /mnt/HD/HD_a2/Public/up.txt /tmp/down.txt\n' | sftp $O -i /client/old_rsa -b - sshd@127.0.0.1 > /dev/null 2>&1
cmp -s /tmp/up.txt /tmp/down.txt && pass "SFTP: a file up and back (the app's sftp-server)" || fail "sftp"
kill "$(cat /var/run/sshd.pid)"; sleep 1; /usr/sbin/ssh_daemon -s
wait_server OpenSSH_10.6 && pass "switched off and on in the dashboard (WD's ssh_daemon -s): the app's sshd again" || fail "WD's restart: $(server)"

echo "== its page"
page_up
ST=$(get status)
FP=$(ssh-keygen -l -f /etc/ssh/ssh_host_rsa_key.pub | cut -d ' ' -f 2)
[ "$(echo "$ST" | j '$d["listener"]')" = '"app"' ] && [ "$(echo "$ST" | j '$d["version"]')" = '"10.6p1"' ] && [ "$(echo "$ST" | j '$d["sandbox"]')" = '"seccomp"' ] \
	&& [ "$(echo "$ST" | j '$d["host_keys"][0]["fingerprint"]')" = "\"$FP\"" ] && [ "$(echo "$ST" | j '$d["home"]["keys"][0]["comment"]')" = '"users-old-key"' ] \
	&& [ "$(echo "$ST" | j '$d["home"]["kept"]')" = false ] && pass "the page: 10.6p1 running (seccomp sandbox), the NAS's fingerprint, the user's own key (in RAM here: lost at a reboot)" \
	|| fail "status: $(echo "$ST" | head -c 400)"

echo "== keys from the page"
post add_key -d 'key=hello there' | grep -q "isn't a public key" && post add_key --data-urlencode "key=$(cat $NEW)" | grep -q "private key" \
	&& post add_key -d 'key=ssh-dss AAAAB3NzaC1kc3MAAACBAP' | grep -q "isn't a public key" \
	&& post add_key --data-urlencode "key=$(ssh-keygen -q -t rsa -b 1024 -N "" -f /tmp/weak > /dev/null 2>&1; cat /tmp/weak.pub)" | grep -q "at least 2048" \
	&& post add_key -d 'key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBroken' | grep -q "damaged" \
	&& pass "refused: not a key, a private key, DSA, a 1024-bit RSA key, a damaged key" || fail "key checks"
R=$(post add_key --data-urlencode "key=$(cat $NEW.pub)" -d "name=Paul's laptop")
[ "$(echo "$R" | j '$d["comment"]')" = "\"Paul's laptop\"" ] && [ "$(key_login $NEW sshd 'echo in')" = in ] \
	&& [ "$(stat -c '%U %a' $D/authorized_keys)" = "root 600" ] && [ "$(stat -c '%U %a' /etc/ssh/authorized_keys.openssh-app)" = "root 600" ] \
	&& pass "a key added on the page logs in straight away (root's only files: the kept one and sshd's copy)" || fail "add key: $R $(key_login $NEW sshd 'echo in')"
post add_key --data-urlencode "key=$(cat $NEW.pub)" | grep -q "already there" && pass "the same key again refused" || fail "duplicate"

echo "== password logins off"
post passwords > /dev/null; wait_server OpenSSH_10.6
[ "$(pw_login sshd Wd-Passw0rd)" != logged-in ] && [ "$(key_login $NEW sshd 'echo in')" = in ] && [ "$(key_login /client/old_rsa sshd 'echo in')" = in ] \
	&& [ "$(get status | j '$d["passwords"]')" = false ] && pass "keys only: the password refused, both keys log in (SSH restarted)" || fail "passwords off: $(pw_login sshd Wd-Passw0rd)"
mv /home/root/.ssh/authorized_keys /tmp/home_keys
FPNEW=$(ssh-keygen -l -f $NEW.pub | cut -d ' ' -f 2)
post remove_key --data-urlencode "fingerprint=$FPNEW" | grep -q "last key" && pass "the last key can't be removed while password logins are off" || fail "last key removed"
mv /tmp/home_keys /home/root/.ssh/authorized_keys
post passwords -d on=1 > /dev/null; wait_server OpenSSH_10.6
[ "$(pw_login sshd Wd-Passw0rd)" = logged-in ] && pass "...and the password allowed again" || fail "passwords on"
post remove_key --data-urlencode "fingerprint=$FPNEW" > /dev/null
key_login $NEW sshd 'echo in' | grep -q "denied" && pass "a key removed on the page can't log in" || fail "removed key still logs in"
post add_key --data-urlencode "key=$(cat $NEW.pub)" > /dev/null

echo "== falling back to WD's sshd"
sh $P/openssh/stop.sh $P/openssh > /dev/null 2>&1; wait_server OpenSSH_8.4p1
mv $P/openssh/binaries/libexec/sshd-session /tmp/sshd-session
sh $P/openssh/start.sh $P/openssh > /dev/null 2>&1
wait_server OpenSSH_8.4p1 && [ "$(readlink /usr/sbin/sshd)" = /usr/local/modules/usr/sbin/sshd ] && [ "$(key_login /client/old_rsa sshd 'echo in')" = in ] \
	&& get status | grep -q "trial login" && pass "a broken 10.6 fails its trial: WD's sshd keeps running, the page says why" || fail "fallback: $(server) $(get status | head -c 300)"
mv /tmp/sshd-session $P/openssh/binaries/libexec/sshd-session
post restart > /dev/null
wait_server OpenSSH_10.6 && [ "$(get status | j '$d["fallback"]')" = '""' ] && pass "Restart SSH on the page: 10.6 again" || fail "after the fix: $(server)"

echo "== no seccomp filters"
sh $P/openssh/stop.sh $P/openssh > /dev/null 2>&1; wait_server OpenSSH_8.4p1
mv $P/openssh/binaries/bin/seccomp_check /tmp/seccomp_check; printf '#!/bin/sh\nexit 2\n' > $P/openssh/binaries/bin/seccomp_check; chmod 755 $P/openssh/binaries/bin/seccomp_check
sh $P/openssh/start.sh $P/openssh > /dev/null 2>&1
wait_server OpenSSH_10.6 && [ "$(readlink /usr/local/openssh/libexec/sshd-auth)" = $P/openssh/binaries/libexec-nosandbox/sshd-auth ] \
	&& [ "$(get status | j '$d["sandbox"]')" = '"none"' ] && [ "$(key_login $NEW sshd 'echo in')" = in ] \
	&& pass "a kernel without seccomp filters: 10.6 without its sandbox, logins work" || fail "no seccomp: $(server) $(readlink /usr/local/openssh/libexec/sshd-auth)"
mv -f /tmp/seccomp_check $P/openssh/binaries/bin/seccomp_check

echo "== a reboot"
# (RAM is wiped: WD's links and users are back, WD's sshd starts - then the app's init.sh and start.sh run)
kill "$(cat /var/run/sshd.pid)"; sleep 1
rm -rf /usr/local/openssh /etc/ssh/authorized_keys.openssh-app /var/run/openssh-app.*
ln -sf /usr/local/modules/usr/sbin/sshd /usr/sbin/sshd; ln -sf /usr/local/modules/usr/bin/sftp-server /usr/bin/sftp-server
sed -i '/^sshpriv:/d' /etc/passwd /etc/group /etc/shadow
/usr/sbin/ssh_daemon -s; wait_server OpenSSH_8.4p1
sh $P/openssh/init.sh $P/openssh > /dev/null 2>&1; sh $P/openssh/start.sh $P/openssh > /dev/null 2>&1
wait_server OpenSSH_10.6 && [ "$(key_login $NEW sshd 'echo in')" = in ] && pass "after a reboot: 10.6 again, the page's key still logs in" || fail "reboot: $(server) $(tail -n 4 /tmp/debug_apkg)"

echo "== switched back (stopped)"
sh $P/openssh/stop.sh $P/openssh > /dev/null 2>&1
wait_server OpenSSH_8.4p1 && [ "$(readlink /usr/sbin/sshd)" = /usr/local/modules/usr/sbin/sshd ] && [ "$(readlink /usr/bin/sftp-server)" = /usr/local/modules/usr/bin/sftp-server ] \
	&& [ ! -e /usr/local/openssh ] && [ ! -e /etc/ssh/authorized_keys.openssh-app ] && [ "$(key_login /client/old_rsa sshd 'echo in')" = in ] \
	&& pass "WD's 8.4p1 back on port 22 with WD's links; the user's own key still logs in" || fail "restore: $(server) $(readlink /usr/sbin/sshd)"

echo "== removed"
finish_app
wait_server OpenSSH_8.4p1 && grep -q "laptop" $D/authorized_keys && pass "WD's sshd running; the page's keys kept for a reinstall" || fail "after removal"
