# Vaultwarden App

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) is a lightweight server for the Bitwarden password manager: the official Bitwarden apps, browser extensions and its web vault all work with it. It runs natively on the NAS *(no Docker)*, using about 20–50MB of memory.

- **Needs the [Nginx app](../nginx/README.md)** *(`InstDepend` in `apkg.rc`, so the NAS won't install it without)*: Bitwarden's web vault and apps only work over HTTPS. Vaultwarden listens on the NAS itself only *(`127.0.0.1:8222`)*, and the Nginx app serves it at `https://vaultwarden.<its domain>`, with its certificate - the site is added automatically, and can be renamed or switched off on the Nginx app's page.
- It runs as its own `vaultwarden` user *(created by the app, ID 71)*, not as root.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_vaultwarden`, and survives reinstalls and removal:
  - `data/` - Vaultwarden's own data: the SQLite database `db.sqlite3`, attachments, sends, its keys and the admin panel's settings *(`config.json`)*, readable only by its user
  - `admin_token` - the admin panel's token *(root only; Vaultwarden is given only its Argon2 hash)*
  - `settings` - the management page's settings
  - `backups/` - the daily backups *(unless another folder is chosen)*
  - `vaultwarden.log` - its warnings and errors *(e.g. failed logins), kept under 1MB*
- The database is SQLite: a single file, nothing else to run.
- It's built from Vaultwarden's official Alpine image *(a static program, plus the web vault)* by `static/vaultwarden`, which also builds the tools used alongside it: `sqlite3` *(for backups)*, `argon2` *(to hash the admin token)* and `vw_runas` *(to switch to its user - the NAS has no `su`)*.
- Vaultwarden doesn't update itself: updates come with new versions of the app, and the NAS shows an alert *(and sends an email, if set up)* when a new release is out, checked weekly.

## Management page

Vaultwarden's page in the NAS dashboard *(Apps → Vaultwarden)* shows whether it's running, its version and address, with links to it and its admin panel. It can:

- allow or stop new accounts signing up *(on at first, so that you can create yours - turn it off afterwards; others can still be invited from the admin panel)*
- show, copy or replace the admin panel's token
- set the backup folder and how many backups to keep, back up straight away, and list the backups
- restart Vaultwarden, and show its latest warnings

Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

Settings saved in Vaultwarden's own admin panel override the app's: when the sign-up setting or the admin token has been saved there, the page changes it there too.

## First steps

1. In the Nginx app, set up the domain and certificate *(e.g. `nas.example.com` with `*.nas.example.com`)*, and the local DNS records it lists.
2. Open `https://vaultwarden.<domain>` and create your account. Your master password can't be recovered by anyone *(it's never sent to the server)* - keep it safe.
3. Turn sign-ups off on the management page.
4. Optionally, in the admin panel *(`https://vaultwarden.<domain>/admin`, with the token from the management page)*, set up email *(needed for invitations and email two-step login)*.
5. In the Bitwarden apps and extensions, choose **self-hosted** when logging in, with the server URL `https://vaultwarden.<domain>`.

The Nginx app is reachable from the local network only by default, so Vaultwarden is too: devices sync whenever they're at home, and keep working offline with their own copy of the vault in between. Using it from outside means making the Nginx app reachable from the internet *(or a VPN)* - think carefully about that for a password manager.

## Backups

Every day at 02:15, and on the page's **Back up now**, the app writes `vaultwarden-<date>-<time>.tar.gz` to the backup folder, holding:

- `db.sqlite3` - a consistent copy of the database, made with SQLite's online backup while Vaultwarden runs *(and checked)*
- `attachments/`, `sends/`, the `rsa_key*` files *(which sign logins)* and `config.json` *(the admin panel's settings)*

The newest backups are kept *(14 by default)*. They're readable by root only, as they hold the admin panel's settings *(which may include an email password)* - the vault data itself is encrypted with each user's master password.

To restore one over SSH *(the app's folder may be on another volume)*:

```sh
sh /mnt/HD/HD_a2/Nas_Prog/vaultwarden/vw_ctl.sh stop
cd /mnt/HD/HD_a2/Nas_Prog/_vaultwarden
mv data data.old
mkdir data && tar -xzf backups/vaultwarden-<date>-<time>.tar.gz -C data
chown -R vaultwarden:vaultwarden data && chmod 700 data
sh /mnt/HD/HD_a2/Nas_Prog/vaultwarden/vw_ctl.sh start
```

Copy backups somewhere other than the NAS too *(e.g. choose a folder on a USB drive)*.

## Building the Vaultwarden app

From the project root directory:

```bash
./build.sh vaultwarden
```

This first runs `static/vaultwarden` *(once per version)*, which copies Vaultwarden out of its official image *(pinned by digest in `static/vaultwarden/amd64.Dockerfile`)* and builds the tools. The WD bin files will be created in `packages/vaultwarden/`. To update, change the version in `apkg.rc`, `static/vaultwarden/build.sh` and the Dockerfile's image tag and digest.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
