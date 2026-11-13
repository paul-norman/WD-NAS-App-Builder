# phpBB App

[phpBB](https://www.phpbb.com/) is a long-standing discussion forum: categories and forums of topics and posts, with registered users, groups, permissions, private messages, attachments, polls, search, moderation, styles and extensions. It replaces the phpBB that WD's old app store offered *(long out of date)*. It runs natively on the NAS *(no Docker)* on the [PHP app](../php/README.md)'s PHP 8.5 *(which it needs: install that first)*, and keeps its posts in the NAS's own MariaDB *(WD's, or the [MariaDB app](../mariadb/README.md)'s)*.

- Its address is `https://phpbb.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - rename it there, e.g. to `forum`)*. With the Nginx app installed, phpBB is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8089`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8089` on the local network, over plain HTTP.
- **The board is installed on its first start** *(phpBB's own installer, run by the app)*: English, its administrator `admin` with a password the app generates *(shown on the management page, which can also change it - even after the name has been changed in phpBB)*, and no email until a mail server is set up in phpBB *(Administration Control Panel, General, Email settings)*. People then register on the board; while there's no email, accounts that need activating are activated by an administrator.
- **Its address is set at every start**: the Nginx app's site when there is one, else the NAS's own address on port 8089 *(phpBB makes its links from it)* - restart phpBB after setting the Nginx app's domain. Its cookies are for that address only, and secure-only when it's only reachable over HTTPS.
- **Its database**: the app makes a login and a database of its own in MariaDB *(both `phpbb`, `utf8mb4`, tables prefixed `phpbb_`; all rights on that database, none elsewhere)*, over MariaDB's socket. WD's MariaDB only runs when an app asks for it: the app starts it *(the way WD's phpMyAdmin does)* if it isn't running. At boot, if MariaDB isn't answering yet, phpBB waits for it *(up to 5 minutes, in the background)*. After an update, its database is brought up to date at the next start *(phpBB's own `db:migrate`)*.
- **Its private folders are never served**: PHP's web server runs it through the app's router, which refuses what phpBB's own `.htaccess` files and sample Nginx configuration protect *(its settings, cache, attachments, uploaded avatars, backups and logs, code and packages)*.
- **Extensions** go in `Nas_Prog/_phpbb/ext` *(e.g. `ext/vendor/name/`, copied there over SSH - see the [OpenSSH app](../openssh/README.md))*, then are enabled in the Administration Control Panel, Customise. Extra styles and language packs are part of the app's folder, which an update replaces - add them again after one. Not included: the VigLink extension phpBB's own packages have *(it turns links in posts into affiliate links)*.
- **Backups**: every day at 03:45, one archive with its database *(`phpbb.sql`, dumped while it runs)*, its attachments *(`files/`)*, uploaded avatars *(`avatars/`)* and extensions *(`ext/`)*, into `Nas_Prog/_phpbb/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one: stop phpBB, then

  ```sh
  mkdir /tmp/restore && tar -xzf phpbb-<date>.tar.gz -C /tmp/restore
  mysql --socket=/var/lib/mysql/mysql.sock -uroot phpbb < /tmp/restore/phpbb.sql
  cp -a /tmp/restore/files /tmp/restore/avatars /tmp/restore/ext /mnt/HD/HD_a2/Nas_Prog/_phpbb/
  ```

  and start it again.
- It runs as its own user *(`phpbb`, ID 69)*, on PHP's own web server with 4 workers *(enough for a family or a club; opcache on)*. Its data is kept in `Nas_Prog/_phpbb`, across reinstalls and removal: `cache/`, `store/` *(phpBB's own backups and logs)*, `files/` and `avatars/` are phpBB's own; its settings *(`conf/config.php`, written by the app at every start)*, passwords and backups are root's. Its database stays in MariaDB when the app is removed *(drop it there to start afresh: `DROP DATABASE phpbb; DROP USER 'phpbb'@'localhost';`, and delete `Nas_Prog/_phpbb`)*.
- Moving from WD's old phpBB *(or another board)*: phpBB's converters and its update packages need its own installer, which the app keeps aside *(`install.dist`)* - the simplest route is a fresh board here.
- The app checks weekly for a new phpBB release in the 3.3 line *(a NAS alert)*.
- It's phpBB's release tag *(its source, checked by its SHA256 - phpBB's own download site refuses scripted downloads)* with its PHP packages installed by Composer *(exactly those in its `composer.lock`)*, as phpBB's own packages are made. phpBB is GPL-2.0 licensed. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS)*.

## Building the phpBB app

From the project root directory:

```bash
./build.sh phpbb
```

This first runs `static/phpbb` *(once per version)*. The WD bin files will be created in `packages/phpbb/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
