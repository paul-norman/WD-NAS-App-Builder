# Memos App

[Memos](https://usememos.com/) is for quick notes: write in Markdown, tag with `#tags`, search, pin and link them, attach files - a private timeline of thoughts, kept on the NAS and used from any browser *(phones too)*. The app runs it natively on the NAS *(no Docker)*, with its notes in SQLite.

For the Intel and ARM models *(the ARM ones' package is checked under emulation when it's built, but hasn't yet been tried on an ARM NAS)*.

- **Its web interface** is on port 5230 - by default, with the Nginx app installed, only through it, at `https://memos.<domain>` *(the page's setting: on the network too, over plain HTTP)*. Memos is told its address *(the Nginx app's site, else the NAS's own on port 5230)* for its links: restart it from the page if the Nginx app's address changes.
- **Nobody else can claim it.** A new Memos makes the first account to sign up its administrator; the app makes that account itself before anyone can reach it - `admin`, with a generated password the page shows, copies or resets. It's declared in Memos' own [configuration files](https://github.com/usememos/memos/blob/main/docs/design/declarative-configuration.md) *(`Nas_Prog/_memos/config/app.json`, applied by Memos at every start; the password read from `admin_password`, root's and Memos' group's only)*. The password is only sent when the page resets it, so you can change it in Memos' settings too - the page then no longer knows it until you reset it.
- **No sign-ups.** Memos lets anyone who reaches it create an account by default: on its first start the app turns that off, then hands the setting back to Memos *(Settings in Memos: add other people's accounts there, or allow sign-ups)*. Notes are private to each account unless shared.
- **Backups** every night at 02:55, and from the page: Memos' database *(copied safely while it runs, with SQLite's own backup, and checked)* and its attachments, as one `.tar.gz` in `Nas_Prog/_memos/backups` *(root's only; the newest 14 kept, set on the page)*. To restore one: stop Memos *(the dashboard's switch)*, unpack it into `Nas_Prog/_memos/data`, start it again.
- Memos runs as its own `memos` user *(created by the app, ID 61)*. Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_memos`, and survives reinstalls and removal: `data/` *(the database and attachments - its user's only)*, `config/`, the admin password, backups, the page's settings and `memos.log` *(kept under 1MB)*.
- Memos is the official program from its releases. It doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Memos' page in the NAS dashboard *(Apps → Memos)* shows whether it's running, its version and its addresses, the admin login *(with the password)* and the latest backup. It resets the admin password, backs up now, sets whether it's only reachable through the Nginx app and how many backups are kept, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Memos app

From the project root directory:

```bash
./build.sh memos
```

This first runs `static/memos` *(once per version: Memos' release for each architecture, checked against its SHA256, and SQLite's shell for the backups)*. The WD bin files will be created in `packages/memos/`. To update, change the version in `apkg.rc` and `static/memos/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
