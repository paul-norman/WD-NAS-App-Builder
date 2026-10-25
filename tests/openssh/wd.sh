#!/bin/sh
# Sets the stand-in out as the NAS has its SSH server (none of WD's own files - stand-ins for them): OpenSSH 8.4p1 at
# /usr/local/modules/usr/sbin/sshd behind the /usr/sbin/sshd link (and its sftp-server likewise), WD's sshd_config, an
# RSA host key only, the login user sshd with root's ID (and an MD5 password with an empty salt, as WD's), root's home
# in RAM with a key of the user's own, and WD's ssh_daemon -s, which starts it as WD does
mkdir -p /usr/local/modules/usr/sbin /usr/local/modules/usr/bin /run/sshd /home/root/.ssh /etc/ssh
mv /usr/sbin/sshd /usr/local/modules/usr/sbin/sshd
cp /usr/lib/openssh/sftp-server /usr/local/modules/usr/bin/sftp-server
ln -sf /usr/local/modules/usr/sbin/sshd /usr/sbin/sshd
ln -sf /usr/local/modules/usr/bin/sftp-server /usr/bin/sftp-server
rm -f /etc/ssh/ssh_host_* /etc/ssh/sshd_config.d/*
ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key
cat > /etc/ssh/sshd_config <<'EOF2'
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
SyslogFacility AUTHPRIV
AllowUsers sshd
PermitRootLogin yes
PubkeyAuthentication yes
PermitEmptyPasswords yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
TCPKeepAlive yes
MaxAuthTries 5
Subsystem sftp /usr/bin/sftp-server
EOF2
# (Debian's own sshd user goes: WD's is the login user, with root's ID - and root's password, here Wd-Passw0rd)
HASH=$(openssl passwd -1 -salt '' 'Wd-Passw0rd')
sed -i '/^sshd:/d' /etc/passwd /etc/shadow /etc/group
echo 'sshd:x:0:0:Linux User,,,:/home/root:/bin/sh' >> /etc/passwd
echo "sshd:${HASH}:19000:0:99999:7:::" >> /etc/shadow
sed -i "s|^root:[^:]*:|root:${HASH}:|" /etc/shadow
sed -i 's|^root:x:0:0:[^:]*:[^:]*:|root:x:0:0:Linux User,,,:/home/root:|' /etc/passwd
# The user's computer's key, already on the NAS (as one put there long ago)
mkdir -p /client && ssh-keygen -q -t rsa -b 3072 -N '' -C 'users-old-key' -f /client/old_rsa
cp /client/old_rsa.pub /home/root/.ssh/authorized_keys
chmod 700 /home/root/.ssh; chmod 600 /home/root/.ssh/authorized_keys
cat > /usr/sbin/ssh_daemon <<'EOF2'
#!/bin/sh
[ "$1" = -s ] && exec /usr/sbin/sshd -E /var/log/sshd.log -f /etc/ssh/sshd_config
EOF2
chmod 755 /usr/sbin/ssh_daemon
/usr/sbin/ssh_daemon -s
