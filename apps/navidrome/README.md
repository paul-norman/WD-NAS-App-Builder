# Navidrome App

[Navidrome](https://www.navidrome.org/) streams your music collection to a browser *(its own web player)* and to phones and desktop players through the **Subsonic** API, which many apps speak: e.g. Symfonium, Tempo or Substreamer on Android, play:Sub or Amperfy on iPhone, Feishin on the desktop. It handles large collections, multiple users *(each with their own playlists, favourites and play counts)*, and transcodes on the fly *(e.g. FLAC to Opus for a phone on mobile data)*. It runs natively on the NAS *(no Docker)*.

- It's at `https://navidrome.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically)*, and at `http://<nas-ip>:4533` on the local network unless limited to the Nginx app on the management page.
- **The music folder** is set on the management page *(by default WD's `Public/Shared Music` if there is one, otherwise the `Public` share)*. Navidrome only reads it: it runs as its own `navidrome` user *(created by the app, ID 78)*, so the folder must be readable by everyone - shares normally are. More folders can be added as extra libraries in Navidrome *(Settings → Libraries)*. New and changed files are picked up as they appear, and everything is checked once a day.
- **Users**: the app creates an `admin` user with a generated password *(the management page shows, copies or replaces it)*. Create a user for each person in Navidrome *(Settings → Users)*, and log in to the apps with those. The management page logs in as `admin` with the app's password for its library details and scans.
- **Transcoding** uses a small ffmpeg built for audio only *(Opus, MP3, AAC, FLAC and WAV out; the common music formats in)*, included in the app - it doesn't need the NAS's or Jellyfin's.
- **Privacy**: artist images and biographies from Deezer, Last.fm and ListenBrainz are off by default *(a switch on the management page)*, and so are Navidrome's anonymous usage statistics and its plugins.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_navidrome`, and survives reinstalls and removal: the database *(users, playlists, favourites, play counts)*, caches and the generated `navidrome.toml` in `data/`, the database backups *(made by Navidrome every night, keeping 7)* in `backups/`, the admin password and the key that encrypts the users' passwords *(root only)*, the page's settings, and `navidrome.log` *(warnings only, kept under 1MB)*. The music itself stays where it is.
- It's the official static program *(prepared by `static/navidrome`, with ffmpeg)*. Navidrome doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Navidrome's page in the NAS dashboard *(Apps → Navidrome)* shows whether it's running, its version and addresses, and each library *(its folder, numbers of songs, albums and artists, size and last scan)*. It scans for changes or rescans everything, shows, copies or replaces the admin user's password, sets the music folder *(checking that Navidrome can read it)*, limits access to the Nginx app, turns artist images and biographies on or off, restarts Navidrome, and lists the backups and its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Navidrome app

From the project root directory:

```bash
./build.sh navidrome
```

This first runs `static/navidrome` *(once per version)*, which downloads Navidrome and builds ffmpeg. The WD bin files will be created in `packages/navidrome/`. To update, change the version in `apkg.rc` and `static/navidrome/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
