# Music Assistant App

[Music Assistant](https://www.music-assistant.io/) brings your own music collection and your streaming services *(Spotify, YouTube Music, Tidal, Qobuz, Deezer, internet radio, podcasts, Plex, Jellyfin, Navidrome / Subsonic and more)* together in one library, and plays it on the speakers in your home: **Sonos**, Chromecast, DLNA / UPnP, Squeezebox, Snapcast and others - with groups, queues and playlists that mix sources. It runs natively on the NAS *(no Docker)*, with its own Python, and doesn't need Home Assistant.

- Its web interface is at `http://<nas-ip>:8095`, and at `https://music.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically)*. It always listens on the network as well: the speakers fetch the music from it there.
- It runs straight on the NAS's network, so it finds the players by itself *(e.g. Sonos speakers, through their own discovery)* once their provider is added in its settings. The speakers must be on the same network as the NAS.
- **Users**: the app creates the `admin` user itself on the first start, with a generated password *(the management page shows, copies or replaces it)* - so nobody else on the network can claim Music Assistant first. Create a user for each person in Music Assistant *(Settings → Users)*.
- **Your music**: add the "Local disk" provider with a folder on the NAS, e.g. `/mnt/HD/HD_a2/Public/Music`. Music Assistant runs as its own `musicassistant` user *(created by the app, ID 79)* and only reads it, so the folder must be readable by everyone - shares normally are.
- **Streaming services**: added the same way, each with its own login *(Spotify needs Premium; YouTube Music works through unofficial access, which breaks from time to time when Google changes things)*.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_music-assistant`, and survives reinstalls and removal: its settings, library and users in `data/` *(with its cache and its own log, `musicassistant.log`)*, daily backups of them in `backups/` *(keeping 7; Music Assistant stops for a minute for each, at 03:50, as it keeps its databases locked while it runs)*, the admin password and the page's access token *(root only)*, and `console.log` *(its output, kept under 1MB)*.
- Music Assistant doesn't update itself here: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly. The first start after an install or update takes a minute or two.

## What's left out

The app is Music Assistant's official release with its own Python *(a portable build of the version it needs)*, every package its features use, and a static ffmpeg - all prepared by `static/music-assistant`. Except:

- **On-device audio analysis** *(smart crossfades, sonic similarity)*: it needs a CPU with AVX2, which no WD NAS has, so its packages *(PyTorch and others, several GB)* aren't included. Music Assistant turns these features off by itself.
- **AirPlay speakers**: its AirPlay sender needs a newer system library *(glibc)* than the NAS has.
- **Remote access** *(through Music Assistant's own WebRTC service)*: its library isn't released yet. Use a VPN, or the Nginx app's site, instead.

## Management page

Music Assistant's page in the NAS dashboard *(Apps → Music Assistant)* shows whether it's running, its version and addresses, and the players it has found. It shows, copies or replaces the admin user's password, makes and lists backups, restarts Music Assistant, and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Music Assistant app

From the project root directory:

```bash
./build.sh music-assistant
```

This first runs `static/music-assistant` *(once per version)*, which installs Music Assistant into its own Python on the NAS's Debian version *(so its compiled parts suit the NAS)* and builds ffmpeg. The WD bin files will be created in `packages/music-assistant/`. To update, change the version in `apkg.rc` and `static/music-assistant/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
