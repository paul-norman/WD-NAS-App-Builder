# Homebox App

[Homebox](https://homebox.software/) is a home inventory: what you own and where it is *(rooms, boxes, shelves)*, with photos, receipts, manuals, warranties, serial numbers, prices and maintenance notes - searchable, with printable QR labels, and shared with the household. The app runs it natively on the NAS *(no Docker)*, with its inventory in SQLite.

For the Intel models only: Homebox publishes no build for the ARM models' 32-bit processors.

- **Its web interface** is on port 7745 - by default, with the Nginx app installed, only through it, at `https://homebox.<domain>` *(the page's setting: on the network too, over plain HTTP)*. Homebox is told its address *(the Nginx app's site, else the NAS's own on port 7745)* for the links it makes, e.g. on QR labels and in password reset links: restart it from the page if the Nginx app's address changes.
- **Nobody else can claim it.** A new Homebox lets whoever signs up first in. On its first start the app runs it on the NAS itself only, with sign-ups allowed just long enough to make the admin account itself - `admin@homebox.local`, with a generated password the page shows, copies or resets. You can change the account's email and password in Homebox *(Profile)*: the page then no longer knows the password, and Reset the password only works while the email is still `admin@homebox.local` - a reset link *(below)* works for any address.
- **No sign-ups.** After that first start, sign-ups are off *(the page can turn them on)*. Add the rest of the household with Homebox's own **invitation links** *(Collection Options → invite)*, which work while sign-ups are off; each person gets their own login to the same inventory.
- **A forgotten password**: Homebox can't email a reset link without a mail server, so the page makes one, with Homebox's own `reset-password` command - for any account, by its email address; it works once, within an hour.
- **Backups** every night at 02:50, and from the page: Homebox's database *(copied safely while it runs, with SQLite's own backup, and checked)* and its attachments *(photos, receipts, manuals)*, as one `.tar.gz` in `Nas_Prog/_homebox/backups` *(root's only; the newest 14 kept, set on the page)*. To restore one: stop Homebox *(the dashboard's switch)*, unpack it into `Nas_Prog/_homebox/data`, start it again.
- Homebox runs as its own `homebox` user *(created by the app, ID 58)*. Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_homebox`, and survives reinstalls and removal: `data/` *(the database and attachments - its user's only)*, `tmp/` *(its temporary files: uploads are moved from there into `data/`, which needs both on the same disk - the NAS's `/tmp` is in memory)*, its secret for API keys *(`api_key_pepper`: Homebox won't start without one, and a new one would void every API key)*, the admin password, backups, the page's settings and `homebox.log` *(kept under 1MB)*.
- Uploads of up to 100MB each *(Homebox's own default is 10MB)*. Homebox's check for new releases on GitHub and its analytics are off: the NAS shows an alert when a new release is out, checked weekly.
- Homebox is the official program from its releases. It doesn't update itself: updates come with new versions of the app.

## Management page

Homebox's page in the NAS dashboard *(Apps → Homebox)* shows whether it's running, its version and its addresses, the admin login *(with the password)* and the latest backup. It resets the admin password, makes a password reset link for any account, backs up now, sets whether it's only reachable through the Nginx app, whether anyone can sign up and how many backups are kept, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Homebox app

From the project root directory:

```bash
./build.sh homebox
```

This first runs `static/homebox` *(once per version: Homebox's release, checked against its SHA256, SQLite's shell for the backups, and the run-as helper)*. The WD bin files will be created in `packages/homebox/`. To update, change the version in `apkg.rc` and `static/homebox/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
