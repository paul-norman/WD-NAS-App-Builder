# Firefly III App

[Firefly III](https://www.firefly-iii.org/) is a self-hosted personal finance manager: **accounts** *(current, savings, credit cards, loans and other debts)*, **transactions** *(withdrawals, deposits, transfers - split, tagged, with notes and attachments)*, **budgets** *(including automatic ones)*, **bills** / subscriptions, categories, piggy banks, recurring transactions, **rules** that file new transactions for you, many currencies, and reports and charts. It has a full REST API *(for its [Data Importer](https://docs.firefly-iii.org/how-to/data-importer/installation/), and mobile apps)*. It runs natively on the NAS *(no Docker)* on the [PHP app](../php/README.md)'s PHP 8.5 *(which it needs: install that first)*, and keeps its data in the NAS's own MariaDB *(WD's, or the [MariaDB app](../mariadb/README.md)'s)*.

- Its address is `https://firefly.<domain>`, through the [Nginx app](../nginx/README.md) *(added automatically - rename it there, e.g. to `money`)*. With the Nginx app installed, Firefly III is **only reachable through it** by default *(it listens on the NAS itself only, `127.0.0.1:8088`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8088` on the local network, over plain HTTP. Its address is set at every start *(the Nginx app's site when there is one, else the NAS's own address on port 8088)*: restart it if that changes.
- **Its owner** *(Firefly III's first user, who manages the others)* logs in as `admin@nas.local`, with a password the app generates on its first start *(shown on the management page, which can also change it - even after the email address has been changed in Firefly III)*. The owner is made before its web server first starts, so **nobody else can sign up**. Other people are invited by the owner in Firefly III *(Options, Administration, Users - each with their own finances)*. Two-factor authentication can be turned on in Firefly III's profile page.
- **Its database**: the app makes a login and a database of its own in MariaDB *(both `firefly`, `utf8mb4`; all rights on that database, none elsewhere)*, over MariaDB's socket. WD's MariaDB only runs when an app asks for it: the app starts it *(the way WD's phpMyAdmin does)* if it isn't running. At boot, if MariaDB isn't answering yet, Firefly III waits for it *(up to 5 minutes, in the background)*. After an update of the app *(a new Firefly III)*, its database is brought up to date by Firefly III's own upgrade on its next start. WD's MariaDB keeps its data on the NAS's small system partition *(under 1GB)*: plenty for years of transactions - attachments are kept on the data volume.
- **Its own daily jobs** *(recurring transactions created, automatic budgets set, bill reminders)* run every day at 03:35 *(Firefly III's `firefly-iii:cron`)*.
- **Attachments** *(receipts, statements)* are kept in `Nas_Prog/_firefly-iii/storage/upload`, and only shown to their owner.
- **Email**: none by default *(Firefly III's emails are written to its log)*. To send them *(invitations, password resets, bill reminders)*, add its mail settings to `Nas_Prog/_firefly-iii/conf/extra.env` *(one `KEY=value` per line, e.g. `MAIL_MAILER=smtp`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_ENCRYPTION`, `MAIL_FROM` - see [Firefly III's documentation](https://docs.firefly-iii.org/) and its `.env.example`)* and restart it. Any other setting of Firefly III's `.env` can go there too.
- **Backups**: every day at 03:35, one archive with its database *(`firefly.sql`, dumped while it runs)*, its attachments *(`upload/`)*, its API's keys *(`oauth-*.key` - without them, its apps and the Data Importer must sign in again)* and its key *(`app_key` - Firefly III can't read what it encrypted without it, e.g. two-factor secrets)*, into `Nas_Prog/_firefly-iii/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one: stop Firefly III, then

  ```sh
  mkdir /tmp/restore && tar -xzf firefly-iii-<date>.tar.gz -C /tmp/restore
  mysql --socket=/var/lib/mysql/mysql.sock -uroot firefly < /tmp/restore/firefly.sql
  cp /tmp/restore/app_key /mnt/HD/HD_a2/Nas_Prog/_firefly-iii/app_key
  cp -a /tmp/restore/upload /tmp/restore/oauth-*.key /mnt/HD/HD_a2/Nas_Prog/_firefly-iii/storage/
  chown -R firefly:firefly /mnt/HD/HD_a2/Nas_Prog/_firefly-iii/storage
  ```

  and start it again.
- It runs as its own user *(`firefly`, ID 55)*, on PHP's own web server with 4 workers *(enough for a family; opcache on)*. Its data is kept in `Nas_Prog/_firefly-iii`, across reinstalls and removal: `storage/` is Firefly III's own *(attachments, API keys, sessions, caches, its log)*; its settings *(`conf/.env`, written by the app at every start)*, passwords, key and backups are root's. Its database stays in MariaDB when the app is removed *(drop it there to start afresh: `DROP DATABASE firefly; DROP USER 'firefly'@'localhost';`, and delete `Nas_Prog/_firefly-iii`)*.
- The app checks weekly for a new Firefly III release *(a NAS alert)*.
- It's Firefly III's own release *(its source with its PHP packages and its built web interface - checked by its SHA256)*. Firefly III is AGPL-3.0 licensed. For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built, but haven't yet been tried on an ARM NAS - Firefly III is heavier than most PHP apps, so expect it to be slow there)*.

## Building the Firefly III app

From the project root directory:

```bash
./build.sh firefly-iii
```

This first runs `static/firefly-iii` *(once per version)*. The WD bin files will be created in `packages/firefly-iii/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
