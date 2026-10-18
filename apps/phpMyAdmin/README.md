# phpMyAdmin

PhpMyAdmin allows the simple management of MySQL (or in this case, MariaDB) databases from a web UI.

## Logging in

Log in as `admin`. A random password is generated on first install and saved, readable by root only, in `Nas_Prog/_phpMyAdmin/admin_password` on the install volume *(e.g. `cat /mnt/HD/HD_a2/Nas_Prog/_phpMyAdmin/admin_password` over SSH)*. It is kept across reinstalls. Password-less logins (e.g. `root`) are disabled, and MySQL is not exposed to the network.

### Changing the admin password

1. Log in to phpMyAdmin as `admin`.
2. On the home page, under **General settings**, click **Change password**, enter the new password and click **Go**.
3. Over SSH, put the new password in the password file so it stays in sync *(edit it with `vi` rather than `echo`, to keep the password out of your shell history)*:

   ```sh
   vi /mnt/HD/HD_a2/Nas_Prog/_phpMyAdmin/admin_password
   ```

   The file is only used to create the `admin` account. Reinstalling the app deletes the account and recreates it with whatever password is in this file, so if you skip this step, a reinstall changes the password back.

### Resetting a forgotten password

Over SSH, set the account back to the password in the file *(adjust the volume to match your install)*:

```sh
PW_FILE=/mnt/HD/HD_a2/Nas_Prog/_phpMyAdmin/admin_password
mysql --user=root --password= -e "ALTER USER 'admin'@'localhost' IDENTIFIED BY '$(cat ${PW_FILE})';"
cat ${PW_FILE}
```

### Things to avoid

- **Don't set a password for MySQL `root`.** The NAS's own scripts *(e.g. `/usr/bin/mysql_reset.py`)* and this app's install and remove scripts log in as `root` with an empty password, and would stop working. `root` can't log in to phpMyAdmin anyway, and MySQL only accepts connections from the NAS itself.
- **Don't add a password-changing page to the app's web folder.** App web pages bypass the NAS login and run as root, so anyone on the network could use it.

## Building the phpMyAdmin app

From the project root directory:

```bash
./build.sh phpMyAdmin
```

The WD bin files will be created in `packages/phpMyAdmin/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.