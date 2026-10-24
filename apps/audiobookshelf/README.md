# Audiobookshelf App

[Audiobookshelf](https://www.audiobookshelf.org/) is an audiobook and podcast server: listen in a browser or in its apps for Android and iPhone, with your place, bookmarks and progress kept across devices. It organises audiobooks with their chapters, covers and series, subscribes to podcasts and downloads new episodes, and can merge an audiobook's files into one M4B. It runs natively on the NAS *(no Docker)*.

- It's at `https://audiobooks.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically, with no upload size limit)*, and at `http://<nas-ip>:13378` on the local network unless limited to the Nginx app on the management page.
- **The root user** *(Audiobookshelf's administrator)* is created by the app on the first start, with a generated password, while Audiobookshelf only answers on the NAS itself - otherwise its setup page would let the first visitor choose it. The management page shows, copies or replaces the password. Create a user for each person in Audiobookshelf *(Settings → Users)*.
- **Libraries** are added in Audiobookshelf *(Settings → Libraries)*: a folder of audiobooks *(one folder per book, e.g. `Audiobooks/Author/Title`)* or of podcasts. New files are picked up as they appear. The management page lists them, with their items, and flags folders Audiobookshelf can't use.
- **On the NAS**, it runs as its own `audiobookshelf` user *(created by the app, ID 83)* in the NAS's `share` group: it can read any share, and what it writes there *(podcast episodes, files it creates)* is writable by the group *(664)* - so it can be changed over SMB too. A merged M4B takes the first original track's place, with its owner and permissions.
- **ffmpeg** *(static, built for the app: every audio format, AAC for its streams and M4B files, WebP for its covers, HTTPS for podcast episodes)* and SQLite's Unicode extension *(nunicode: searches ignore accents, e.g. "cafe" finds "Café")* come with the app. Audiobookshelf's own check for (and download of) these is turned off.
- **Podcast feeds** on your own network *(e.g. a podcast server of your own)* must be listed on the management page: Audiobookshelf refuses private addresses otherwise, so that a feed can't reach the NAS's own services. Feeds on the internet always work.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_audiobookshelf`, and survives reinstalls and removal: `config/` *(its database)*, `metadata/` *(covers, cache, its own logs and the database backups it makes every night)*, the root password and the page's settings *(root only)*, and `audiobookshelf.log` *(kept under 5MB)*. The audiobooks and podcasts stay where they are.
- It's built from Audiobookshelf's source release *(prepared by `static/audiobookshelf`, with its own Node.js - its SQLite module is compiled for one Node version)*. Audiobookshelf doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Audiobookshelf's page in the NAS dashboard *(Apps → Audiobookshelf)* shows whether it's running, its version and addresses; shows, copies or replaces the root user's password; lists the libraries with their folders and items; limits access to the Nginx app and allows podcast feeds on your own network; restarts Audiobookshelf; and shows its latest warnings. It logs in to Audiobookshelf as root, keeping that login *(root only)* rather than logging in at every refresh. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Audiobookshelf app

From the project root directory:

```bash
./build.sh audiobookshelf
```

This first runs `static/audiobookshelf` *(once per version)*, which builds Audiobookshelf's web interface and server from its source, installs its packages on the NAS's Debian version, and builds ffmpeg. The WD bin files will be created in `packages/audiobookshelf/`. To update, change the version in `apkg.rc` and `static/audiobookshelf/build.sh` *(with the new source's checksum)*. Tests: [`tests/audiobookshelf`](../../tests/audiobookshelf/README.md).

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
