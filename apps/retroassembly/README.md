# RetroAssembly App

[RetroAssembly](https://retroassembly.com/) is a retro game library you play in the browser: upload your own games *(NES, SNES, Game Boy, Game Boy Advance, Mega Drive, Master System, PC Engine, arcade and more)*, and it shows them with their box art, and plays them with save states, rewind, shaders and gamepad or keyboard controls. The emulators run in the browser *(libretro's, through [Nostalgist.js](https://nostalgist.js.org/))*, so the NAS only stores the games, saves and library - it runs natively on the NAS *(no Docker)*, with its own Node.js and SQLite. For the Intel models only: it needs Node.js 26, which has no build for the ARM models' 32-bit processors.

- **Its web interface** is at `https://games.<domain>` through the [Nginx app](../nginx/README.md) *(added automatically)* - by default, with the Nginx app installed, only through it *(it listens on the NAS itself only, `127.0.0.1:8098`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8098` on the local network, over plain HTTP.
- **Nobody else can claim it.** RetroAssembly lets anyone who can reach it make an account, and its first account is its admin. So the app's build of it only allows sign-ups when the app says so, and on its first start it runs on the NAS itself only, with sign-ups allowed just long enough to make the admin account itself - `admin`, with a generated password the page shows, copies or resets *(resetting signs the account out everywhere)*.
- **Five sample games to start with**, added to the admin's library on that first start: homebrew games whose authors publish them under open licenses - *Thwaite*, *Concentration Room* and *Libbet and the Magic Floor* by Damian Yerrick, *Double Action Blaster Guys* by NovaSquirrel *(NES and Game Boy)* and *µCity* by Antonio Niño Díaz *(Game Boy Color)*. Each one's description gives its license and project; delete them from each game's menu whenever you like. They come from their authors' own releases *(checksums pinned in `static/retroassembly/build.sh`)*, about 250KB in all.
- **The household**: sign-ups stay off *(the page can turn them on)*. The admin adds other people's accounts in RetroAssembly *(Settings → Accounts)*, each with a library of their own or a view of the admin's.
- **Backups** every night at 02:50, and from the page: RetroAssembly's database *(copied safely while it runs, with SQLite's own backup, and checked)* and its saves, save states and screenshots, as one `.tar.gz` in `Nas_Prog/_retroassembly/backups` *(root's only; the newest 14 kept, set on the page)*. The games themselves aren't in them: they can be large, and you have them already. To restore one: stop RetroAssembly *(the dashboard's switch)*, unpack it into `Nas_Prog/_retroassembly/data`, start it again.
- RetroAssembly runs as its own `retroassembly` user *(created by the app, ID 54)*. Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_retroassembly`, and survives reinstalls and removal: `data/` *(the database, and `storage/`: the games, saves and screenshots - its user's only)*, `tmp/` *(its temporary files, on the same disk - the NAS's `/tmp` is in memory)*, the admin password, backups, the page's settings and `retroassembly.log` *(kept under 1MB)*.
- **What it fetches from the internet**: the browser loads the emulators, box art and some of RetroAssembly's own artwork from public sites *(jsDelivr, and the libretro project's thumbnails)*. To recognise an uploaded game, RetroAssembly sends its file name and checksum to its developer's own lookup service *(on Cloudflare and fly.io)*. It has no analytics: its build sets none up.
- It's RetroAssembly's source as tagged *(GitHub's archive of its tag, pinned by SHA256 in `static/retroassembly/build.sh` - it publishes few releases)*, built as its own Docker image builds it, with two changes the app needs: sign-ups only when the app allows them *(above)*, and listening on the NAS itself only when the page says so *(RetroAssembly always listens on every address)*. Its SQLite module is compiled for the NAS's libraries. The NAS shows an alert when a new version is out *(checked weekly)*.

## Management page

RetroAssembly's page in the NAS dashboard *(Apps → RetroAssembly)* shows whether it's running, its version and its addresses, the admin login *(with the password)* and the latest backup. It resets the admin password, backs up now, sets whether it's only reachable through the Nginx app, whether anyone can sign up and how many backups are kept, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the RetroAssembly app

From the project root directory:

```bash
./build.sh retroassembly
```

This first runs `static/retroassembly` *(once per version: RetroAssembly built from its source with its own Node.js, the sample games, SQLite's shell for the backups, and the run-as helper)*. The WD bin files will be created in `packages/retroassembly/`. To update, change the version in `apkg.rc` and `static/retroassembly/build.sh` *(with the new tag archive's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
