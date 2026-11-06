# BookStack App

[BookStack](https://www.bookstackapp.com/) is a simple, self-hosted wiki organised like a library: **shelves** of **books**, each with **chapters** and **pages** - written in a WYSIWYG or Markdown editor, with page revisions, search, tags, comments, image galleries, attachments, diagrams *(diagrams.net)*, exports *(PDF, HTML, Markdown)*, fine-grained permissions and roles. It runs natively on the NAS *(no Docker)* on the [PHP app](../php/README.md)'s PHP 8.5 *(which it needs: install that first)*, and keeps its pages in the NAS's own MariaDB *(WD's, or the [MariaDB app](../mariadb/README.md)'s)*.

- Its address is `https://bookstack.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - rename it there, e.g. to `wiki`)*. With the Nginx app installed, BookStack is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:6875`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:6875` on the local network, over plain HTTP.
- **Its address is set at every start**: the Nginx app's site when there is one, else the NAS's own address on port 6875 *(BookStack makes all its links from it)*. When it changes *(e.g. the Nginx app set up later, or its domain changed)*, restart BookStack: the app moves the links and images in its pages to the new address *(BookStack's `bookstack:update-url`)*.
- **Its administrator** logs in as `admin@nas.local`, with a password the app generates on its first start *(shown on the management page, which can also change it - even after the email address has been changed in BookStack)*. BookStack's own default login *(`admin@admin.com` / `password`)* is taken over before its web server first starts, so it never works. Other people's accounts are added in BookStack *(Settings, Users)*.
- **Its database**: the app makes a login and a database of its own in MariaDB *(both `bookstack`, `utf8mb4`; all rights on that database, none elsewhere)*, over MariaDB's socket. WD's MariaDB only runs when an app asks for it: the app starts it *(the way WD's phpMyAdmin does)* if it isn't running. At boot, if MariaDB isn't answering yet, BookStack waits for it *(up to 5 minutes, in the background)*. WD's MariaDB keeps its data on the NAS's small system partition *(under 1GB)*: fine for a wiki's text - images and attachments are kept on the data volume.
- **Images and attachments** are kept in `Nas_Prog/_bookstack/storage/uploads` and only shown to people allowed to see their pages *(BookStack's `local_secure_restricted` storage)*.
- **Email**: none by default *(BookStack's emails are written to its log)*. To send them, add BookStack's mail settings to `Nas_Prog/_bookstack/conf/extra.env` *(one `KEY=value` per line, e.g. `MAIL_DRIVER=smtp`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_ENCRYPTION`, `MAIL_FROM` - see [BookStack's guide](https://www.bookstackapp.com/docs/admin/email-webhooks/))* and restart it. Any other setting of BookStack's `.env` can go there too *(e.g. LDAP, OIDC or SAML logins)*.
- **Backups**: every day at 03:35, one archive with its database *(`bookstack.sql`, dumped while it runs)*, its images and attachments *(`uploads/`)* and its key *(`app_key` - BookStack can't read what it encrypted without it, e.g. two-factor secrets)*, into `Nas_Prog/_bookstack/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one: stop BookStack, then

  ```sh
  mkdir /tmp/restore && tar -xzf bookstack-<date>.tar.gz -C /tmp/restore
  mysql --socket=/var/lib/mysql/mysql.sock -uroot bookstack < /tmp/restore/bookstack.sql
  cp /tmp/restore/app_key /mnt/HD/HD_a2/Nas_Prog/_bookstack/app_key
  cp -a /tmp/restore/uploads /mnt/HD/HD_a2/Nas_Prog/_bookstack/storage/ && chown -R bookstack:bookstack /mnt/HD/HD_a2/Nas_Prog/_bookstack/storage
  ```

  and start it again *(its database is brought up to date at every start)*.
- It runs as its own user *(`bookstack`, ID 98)*, on PHP's own web server with 4 workers *(enough for a family; opcache on)*. Its data is kept in `Nas_Prog/_bookstack`, across reinstalls and removal: `storage/` is BookStack's own *(uploads, sessions, caches, its log)*; its settings *(`conf/.env`, written by the app at every start)*, passwords, key and backups are root's. Its database stays in MariaDB when the app is removed *(drop it there to start afresh: `DROP DATABASE bookstack; DROP USER 'bookstack'@'localhost';`, and delete `Nas_Prog/_bookstack`)*.
- The app checks weekly for a new BookStack release *(a NAS alert)*.
- It's BookStack's release *(its source, with its built web interface - checked by its SHA256)* with its PHP packages installed by Composer *(exactly those in its `composer.lock`)*. BookStack is MIT licensed. Intel models only.

## Building the BookStack app

From the project root directory:

```bash
./build.sh bookstack
```

This first runs `static/bookstack` *(once per version)*. The WD bin files will be created in `packages/bookstack/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
