# Forgejo App

[Forgejo](https://forgejo.org/) is your own Git server, like a private GitHub: repositories with a web interface, issues, pull requests, wikis, releases, mirrors of other repositories, and package registries. It runs natively on the NAS *(no Docker)*, on Forgejo's long term support release *(15.x, supported until July 2027)*.

- It's at `https://git.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically, with no size limit for pushes)*, and at `http://<nas-ip>:3002` on the local network unless limited to the Nginx app on the management page.
- **Git over SSH** uses Forgejo's own SSH server on port **2222** *(the NAS's own SSH is left alone)*: `git clone ssh://git@git.<domain>:2222/<user>/<repository>.git`, with the SSH keys added in each user's settings. It can be turned off on the management page.
- **Nobody can see anything without logging in**, and there are no sign-ups. The app creates an admin user, `nas-admin`, with a generated password *(the management page shows, copies or replaces it)*: log in with it, then create your own users under Site administration → User accounts *(or rename `nas-admin` in its settings - the management page then can't reset its password)*. New repositories are private by default *(in the web interface)*.
- It runs as its own `forgejo` user *(created by the app, ID 77)*, not as root, using about 200MB of memory.
- Everything is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_forgejo`, and survives reinstalls and removal: the repositories in `repositories/`, the database, attachments, LFS files and SSH host keys in `data/`, Forgejo's settings in `custom/conf/app.ini`, backups in `backups/`, the admin password *(root only)*, the page's settings, and `forgejo.log` *(warnings only, kept under 1MB)*.
- It includes **Git** *(2.56, built by `static/forgejo`)*, which Forgejo needs for every repository operation - the NAS has none. It's also linked as `/usr/bin/git` *(unless there's one already)*, for your own use over SSH, with HTTPS remotes working too.
- Forgejo is the official static program, for the Intel and ARM models *(on the ARM ones, Forgejo's 32-bit ARM build, and Git cross-compiled with Zig; their packages are checked under emulation when they're built - Forgejo's version, Git making a repository and a commit - but haven't yet been tried on an ARM NAS)*. It doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release of the installed line *(15.x)* is out, checked weekly.

## Settings

`app.ini` is created once, with generated secrets, and is then Forgejo's own: change anything there *(see Forgejo's [configuration cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/) - e.g. `[mailer]` for emails)*, then restart Forgejo on the management page. The app only keeps these current at every start: the address *(`ROOT_URL`, `DOMAIN`, `SSH_DOMAIN` - the Nginx app's site if there is one)*, the listening address *(`HTTP_ADDR`)*, the SSH server and the Git program.

Things turned off by default: emails, update checks, loading avatars from other sites *(`OFFLINE_MODE`)*, and **Forgejo Actions** *(CI)*, which need a separate runner - e.g. Forgejo's runner in Docker - before they can be turned on under `[actions]`.

## Backups

The app backs Forgejo up with its own `forgejo dump` - the repositories, database, settings, attachments and LFS files, in one `.tar.gz` - while it runs. By default weekly *(Sundays at 03:15)*, keeping the newest 4, in `Nas_Prog/_forgejo/backups`; daily or never, how many to keep, and a backup now are on the management page. They're on the NAS itself, so copy them elsewhere too, e.g. with the [Kopia app](../kopia/README.md) *(which can back up the whole `_forgejo` folder instead - the dump is a consistent copy, though)*. To restore, see Forgejo's [backup documentation](https://forgejo.org/docs/latest/admin/command-line/#dump).

## Management page

Forgejo's page in the NAS dashboard *(Apps → Forgejo)* shows whether it's running, its version, web and SSH addresses, the number of repositories and example clone commands. It shows, copies or replaces the admin user's password, makes and lists backups, sets the backup schedule, limits the web interface to the Nginx app, turns Git over SSH on or off, restarts Forgejo, and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Forgejo app

From the project root directory:

```bash
./build.sh forgejo
```

This first runs `static/forgejo` *(once per version)*, which downloads Forgejo and builds Git. The WD bin files will be created in `packages/forgejo/`. To update, change the version in `apkg.rc` and `static/forgejo/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
