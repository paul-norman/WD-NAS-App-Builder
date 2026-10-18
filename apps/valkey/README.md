# ValKey App

ValKey is an open-source, fairly licensed, drop-in replacement for Redis. By default it will run on: `0.0.0.0:6379` and can be accessed via the `valkey-cli` *(or `redis-cli`)* command. The config file is available at `/etc/valkey/valkey.conf`.

## Password

ValKey listens on all interfaces, so a random password is generated on first install. It is the `requirepass` line in the config file *(readable by root only)*:

```sh
grep requirepass /etc/valkey/valkey.conf
```

Connect with `REDISCLI_AUTH=<password> valkey-cli`, or run `valkey-cli` and type `AUTH <password>`. Avoid `valkey-cli -a <password>` where you can, as it leaves the password in your shell history and the process list.

### Changing the password

Passwords can only be changed over SSH. A config page in the NAS web UI would be reachable by anyone on the network without logging in *(app web pages bypass the NAS login and run as root)*, so this app deliberately doesn't have one.

1. Generate a new password *(or choose your own, letters and numbers only)*:

   ```sh
   tr -dc A-Za-z0-9 </dev/urandom | head -c 32; echo
   ```

2. Edit the `requirepass` line in the **real** config file, which lives in persistent storage on the install volume, e.g.:

   ```sh
   vi /mnt/HD/HD_a2/Nas_Prog/_valkey/valkey.conf
   ```

   Don't edit through `/etc/valkey/valkey.conf` with `sed -i` or similar tools: `/etc/valkey/valkey.conf` is a symlink into a RAM disk, and those tools replace the link with a plain file, so the change is silently lost on reboot.

3. Apply it without a restart:

   ```sh
   valkey-cli
   AUTH <old_password>
   CONFIG SET requirepass <new_password>
   ```

   Connections that are already logged in stay open. Don't use `CONFIG REWRITE`, as it writes to `/etc` and has the same symlink problem as above.

   Alternatively, restart ValKey to load the file *(adjust the volume to match your install)*:

   ```sh
   /mnt/HD/HD_a2/Nas_Prog/valkey/stop.sh /mnt/HD/HD_a2/Nas_Prog/valkey
   /mnt/HD/HD_a2/Nas_Prog/valkey/start.sh /mnt/HD/HD_a2/Nas_Prog/valkey
   ```

4. Update any apps or clients that connect to ValKey with the new password.

If the `requirepass` line is ever deleted, a new random password is added the next time the app initialises *(on reboot or reinstall)*. The config file survives reinstalls, so the password is kept.

## Building the ValKey app

From the project root directory:

```bash
./build.sh valkey
```

The WD bin files will be created in `packages/valkey/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.