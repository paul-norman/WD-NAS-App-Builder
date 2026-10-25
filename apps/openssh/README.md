# OpenSSH App

Replaces the NAS's own SSH server - **OpenSSH 8.4p1**, from 2020 - with **OpenSSH 10.6p1**, keeping everything WD set up: its settings, its host key *(so computers that know the NAS don't warn)* and its login *(user `sshd`, with the password set in the dashboard)*. Its page adds SSH keys and a "keys only" switch, and shows how to set up a computer to connect. Intel models only.

- OpenSSH's own release is used *(checked against its SHA256; also signed with OpenSSH's release key)*, built by `static/openssh` fully static against musl, with OpenSSL's libcrypto *(for RSA keys - the NAS's host key is one)*. Nothing depends on the NAS's own libraries, and musl reads `/etc/passwd` and `/etc/shadow` itself: a static glibc build would load the NAS's own user lookup libraries at every login, and break when they change.
- **What's newer**: post-quantum key exchange *(`mlkem768x25519` - OpenSSH 10.1+ clients warn about servers without it)*, the pre-login code in its own process *(`sshd-auth`)* inside a system call sandbox, penalties for addresses that keep failing to log in *(the internet's scanners - except the NAS itself)*, strict key exchange *(against the Terrapin attack)* and six years of fixes.
- **Enabling** the app switches the NAS to OpenSSH 10.6, **disabling** it switches back to WD's 8.4. The NAS's `/` and `/etc` are rebuilt on every boot, so the switch is made again on every boot.
- SSH is still switched on and off in the dashboard *(Settings → Network → SSH)*: with SSH off, the app's sshd starts when it's switched on.

## Keys

Keys added on the app's page log in straight away, are kept across reboots and reinstalls *(in `Nas_Prog/_openssh/authorized_keys`)*, and only need the **public** key pasted *(its type, fingerprint and size are checked: no private keys, no DSA, no RSA under 2048 bits)*. The login user's own `~/.ssh/authorized_keys` works as before and is listed too *(read-only)* - the login user `sshd`'s home is `/home/root`, which WD keeps in RAM *(keys there are lost when the NAS restarts)* unless e.g. the [Entware app](../entware/README.md) gives it a folder on disk.

**Password logins** can be turned off once there's a key: then only keys can log in. The page won't let the last key go while they're off.

The page also shows the NAS's fingerprint *(to check when a computer first connects)*, and the commands and `~/.ssh/config` block for a computer - with the NAS's address filled in:

```
Host nas
    HostName 192.168.1.3
    User sshd
    IdentityFile ~/.ssh/nas_ed25519
    IdentitiesOnly yes
```

Then `ssh nas`, `sftp nas`, `scp file nas:/shares/Public/`. **Don't open SSH's port on your router** - anyone on the internet can then try to log in; use the [WireGuard app](../wireguard/README.md) to reach the NAS from outside.

## How it works

WD starts its sshd with `ssh_daemon -s` *(at boot, and from the dashboard's SSH switch)*, which runs `/usr/sbin/sshd -E /var/log/sshd.log -f /etc/ssh/sshd_config` - `/usr/sbin/sshd` being a link in RAM to WD's binary *(and `/usr/bin/sftp-server` to WD's SFTP server)*. So `ssh_ctl.sh` slips 10.6 underneath, and WD's scripts carry on working:

1. Its own user for privilege separation *(`sshpriv`, ID 85 - WD's `sshd` user is the login user, with root's ID)*, `/var/empty`, and `/usr/local/openssh`: links to the app's programs, where its sshd was built to find its helpers *(`sshd-session`, `sshd-auth`)*. Its sandbox is chosen there: seccomp filters if the NAS's kernel has them *(a tiny check, `seccomp_check`, tries one)* - since 10.4 sshd stops rather than run without its sandbox - or otherwise a build of `sshd-auth` without one *(privilege separation still applies: the pre-login code runs as `sshpriv`, shut in `/var/empty`)*.
2. A **trial**: the app's sshd with WD's configuration on a spare port on the NAS itself, and a login to it - a command and SFTP, with a throwaway key.
3. `/usr/sbin/sshd` links to a launcher for the app's sshd *(adding the page's keys and settings as options - WD's `sshd_config` isn't touched)*, `/usr/bin/sftp-server` to the app's.
4. The running sshd's listener restarts as WD starts it *(the same arguments)* - open sessions stay connected - and the app checks that its sshd took over.

If the configuration test, the trial or the start fails, WD's sshd is put back and started again - and the page says why. `ssh_ctl.sh status` shows what's running; the page *(Apps → OpenSSH)* shows the same, with SSH's log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

Tested on a stand-in for WD's SSH server *(Debian 11's OpenSSH 8.4p1, set out as WD has it)*: see [`tests/openssh`](../../tests/common/README.md).

## Building the OpenSSH app

From the project root directory:

```bash
./build.sh openssh
```

The WD bin files will be created in `packages/openssh/`. The app's version *(`10.6.1` for OpenSSH's `10.6p1`)* is set in `apkg.rc` and `static/openssh/build.sh` *(which must match, with OpenSSH's version and its release's checksum)*.
