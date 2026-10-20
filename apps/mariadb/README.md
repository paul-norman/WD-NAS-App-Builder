# MariaDB App

Replaces the NAS's own MariaDB 10.5 *(out of support since 2025)* with **MariaDB 11.8 LTS** *(supported until 2030)* - e.g. for the [phpMyAdmin app](../phpMyAdmin/README.md). Intel models only.

- MariaDB's own Linux release is used, checked against its published checksum and cut down by `static/mariadb` to what a server needs *(the server, the client tools incl. `mariadb-dump`, `mariadb-backup` and `mariadb-upgrade`, and the plugins that need nothing beyond the NAS's own libraries)*. Its server only needs `libsystemd` to tell systemd it's ready - the NAS doesn't run systemd - so a stand-in library is added.
- **Enabling** the app switches the NAS to MariaDB 11.8, **disabling** it switches back to WD's 10.5. The NAS's `/` and `/etc` are rebuilt on every boot, so the switch is made again on every boot. If 11.8 doesn't start, the NAS goes back to 10.5 by itself.
- It listens where WD's did: the NAS only *(socket `/var/lib/mysql/mysql.sock`, port `3306`)*, with the same accounts *(`root` without a password, which WD's own scripts rely on)*.

## Your data

MariaDB 11.8 converts the data files it runs on, and 10.5 couldn't read them afterwards - so 11.8 runs on **a copy** of WD's data *(`Nas_Prog/_mariadb/data`, made the first time)*, and WD's own data folder stays untouched. Disabling the app brings back 10.5 with WD's data as it was; anything changed under 11.8 stays in the copy *(and is there again when the app is enabled)*. To start over from WD's data, disable the app and delete the copy.

Data that started life on MySQL *(e.g. 5.1, on older firmware)* can have an internal catalogue too inconsistent for 11.8, which then refuses some system tables *(e.g. "Expected tablespace id ... but found ...")* and can't finish upgrading them. Then `mariadb_swap.sh fresh` *(over SSH, in the app's install directory)* starts 11.8 with new, empty system tables instead - the previous copy is kept as `data.old-<date>`, and WD's own data is untouched. Accounts made by other apps *(e.g. phpMyAdmin's `admin`)* are made again by reinstalling them.

## How it works

WD runs MariaDB with `startup-mysql` *(which starts `/usr/bin/mysqld_safe`, which runs `/usr/libexec/mariadbd`)*, and its `mysql_reset.py` *(used e.g. by the phpMyAdmin app)* restarts it with `killall` and finds its data folder in `ps`. So `mariadb_swap.sh` slips 11.8 underneath, and WD's scripts carry on working:

1. `/usr/local/mysql` links to the app's MariaDB - where MariaDB's release looks for its plugins, messages and character sets *(WD's start command passes that plugin folder, which WD's own 10.5 doesn't use)*, and where its server finds the stand-in `libsystemd`.
2. `/usr/libexec/mariadbd` links to 11.8's server *(so it still shows as `/usr/libexec/mariadbd` in `ps`)*.
3. The copy of the data is bind-mounted over WD's data folder *(found from the running server, as WD's script does)*.
4. `/etc/my.cnf` gets a `[mariadb-11.8]` group *(which 10.5 doesn't read)* with WD's socket *(`/var/lib/mysql/mysql.sock` is built into WD's 10.5, while MariaDB's release defaults to `/tmp/mysql.sock`)* and 11.8's messages and character sets, and a `[client]` socket for 11.8's tools - WD's script only ever changes the `bind-address` line.
5. MariaDB restarts through WD's own `startup-mysql`; the first time, `mariadb-upgrade` converts the copy, and its version is also recorded as `mysql_upgrade_info` *(the name WD's script checks, so that it never tries to upgrade the data with 10.5's tools)*.

The switch takes WD's own MariaDB lock, so it never runs at the same time as WD's script. `mariadb_swap.sh status` shows which MariaDB is running *(and `fresh` - see above)*; the app's page in the NAS dashboard *(Apps → MariaDB)* shows the same, with the server's recent warnings and errors. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the MariaDB app

From the project root directory:

```bash
./build.sh mariadb
```

The WD bin files will be created in `packages/mariadb/`. The MariaDB version is set in `apkg.rc` and `static/mariadb/build.sh` *(which must match, with the release's checksum)*.
