# Nextcloud App

[Nextcloud](https://nextcloud.com/) keeps your files, calendars and contacts on the NAS and syncs them with your computers and phones *(its desktop and phone apps, or any WebDAV, CalDAV or CardDAV app)* - with sharing links, a web interface, and hundreds of apps from its app store *(e.g. photos, notes, tasks)*. The app runs it natively on the NAS *(no Docker)*.

For the Intel models only: it runs on the [PHP app](../php/README.md)'s PHP 8.5. It needs three other apps, installed first:

- **[PostgreSQL](../postgresql/README.md)**: Nextcloud's database *(a database and login of its own, `nextcloud`, made by the app - WD's own MariaDB is too old for Nextcloud 35)*.
- **[PHP](../php/README.md)**: its PHP, run as its own php-fpm *(not the NAS's - the PHP app's switch of the NAS's PHP doesn't matter)*.
- **[Nginx](../nginx/README.md)**: its web server *(the Nginx app's program, run as Nextcloud's own)* - and HTTPS, at `https://nextcloud.<domain>`, which Nextcloud's desktop and phone apps expect.

How it works:

- **Its first start installs it** *(a few minutes)*, with an administrator: user name `admin` and a generated password, which the management page shows, copies or replaces. Add everyone else's accounts in Nextcloud itself *(Accounts)*.
- **By default it's only reachable through the Nginx app** *(HTTPS)*. The page can open it on the local network too, at `http://<nas-ip>:8097` - plain HTTP, so passwords then cross the network unencrypted.
- Its web server and PHP run as its own `nextcloud` user *(created by the app, ID 64)*, not root - in the NAS's share group, so that shares can be added to it as **external storage** *(Nextcloud's External storage app, type Local, e.g. `/mnt/HD/HD_a2/Public`)*.
- **Its files** - everyone's - are in its data folder, `Nas_Prog/_nextcloud/data`, not in a share. Files put there some other way are found with the page's **Find new files**.
- Its background jobs run every 5 minutes from cron *(its heavier ones at night)*. Its memory cache is APCu; it uses up to 512MB of memory per PHP worker while busy, and its workers stop when idle.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_nextcloud`, and survives reinstalls and removal: its files *(`data/`)*, its configuration *(`config/` - `config.php` is Nextcloud's, `nas.config.php` the app's: its folders, addresses and proxy, rewritten at every start)*, apps from its app store *(`custom_apps/`)*, its logs, the page's settings and the passwords *(root only)*. Its accounts, shares, calendars and contacts are in its database, in the PostgreSQL app.
- **Backups**: every day at 03:45 the app backs up its database *(pg_dump, readable by root only - the newest 7 by default, in `_nextcloud/backups` or a folder of your choice)*. The files themselves are in `_nextcloud/data`: back that up too, e.g. with the [Kopia app](../kopia/README.md). To restore the database *(over SSH, as root, with the app stopped)*:

  ```sh
  PGPASSWORD="$(cat /mnt/HD/HD_a2/Nas_Prog/_postgresql/postgres_password)" /mnt/HD/HD_a2/Nas_Prog/postgresql/binaries/postgresql/bin/pg_restore \
      -h /var/run/postgresql -U postgres -d nextcloud --clean --if-exists /mnt/HD/HD_a2/Nas_Prog/_nextcloud/backups/nextcloud-<date>.dump
  ```

- **Updates** come with new versions of the app *(Nextcloud's own updater is off)*: the app upgrades its database at the next start. The NAS shows an alert when a new release is out, checked weekly. Its console is `nextcloud_ctl.sh occ ...` in the app's folder *(e.g. `occ status`)*.

## Management page

Nextcloud's page in the NAS dashboard *(Apps → Nextcloud)* shows whether it's running *(and in maintenance mode)*, its version, its addresses and its database, and the administrator's password *(show, copy, or a new one)*. It finds new files, restarts Nextcloud, sets whether it's only reachable through the Nginx app, sets the backups' folder and how many to keep, backs up now and lists the backups, and shows Nextcloud's latest warnings and errors. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Nextcloud app

From the project root directory:

```bash
./build.sh nextcloud
```

This first runs `static/nextcloud` *(once per version)*. The WD bin files will be created in `packages/nextcloud/`. To update, change the version in `apkg.rc` and `static/nextcloud/build.sh` *(with the new release's checksum)* - one major version at a time.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
