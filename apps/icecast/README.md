# Icecast App

[Icecast](https://icecast.org/) is a streaming server: your own internet radio station. Broadcast live from a PC *(e.g. with BUTT, Mixxx or OBS)*, and - with this app - have the NAS broadcast a folder of music by itself, around the clock. Listeners tune in with any music player, browser or radio app. It runs natively on the NAS *(no Docker)*.

- It's at `https://radio.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically)*, and at `http://<nas-ip>:8010` on the local network unless limited to the Nginx app on the management page. A stream's address is its mount point, e.g. `https://radio.<domain>/radio`.
- **The station from a folder** *(off until turned on)*: [ezstream](https://icecast.org/ezstream/) plays every music file in a folder and its subfolders *(MP3, FLAC, Ogg, Opus, AAC/M4A, WAV, WMA, APE, WavPack...; hidden folders left out)*, in order or shuffled, as one MP3 stream *(64 to 320 kbps)* with each track's artist and title. A small audio-only ffmpeg, built for the app, turns each track into the stream's format. New music is found every night, or straight away from the management page, which can also skip to the next track. The folder must be readable by everyone *(shares normally are)*.
- **Live broadcasts**: broadcasting software logs in as `source` with the app's broadcasting password, to a mount point of its choosing *(e.g. `/live`)* on port 8010 - alongside the station.
- **Passwords**: the app generates an admin password *(Icecast's own admin pages, user `admin`)* and a broadcasting password; the management page shows, copies or replaces them.
- **On the NAS**, Icecast runs as its own `icecast` user *(created by the app, ID 82)*. Listeners are limited per stream *(50 by default)*: each takes the stream's quality in upload bandwidth.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_icecast`, and survives reinstalls and removal: the settings and passwords *(root only)*, and `run/` *(Icecast's and ezstream's generated configurations, the station's playlist and the logs)*.
- Built from source, fully static: Icecast 2.5.0, ezstream 1.0.2 *(with libshout 2.4.6 and TagLib, for the tracks' titles)* and ffmpeg *(audio only, with LAME)*. Two small fixes are made to the sources as they're built: ezstream marks its MP3 streams as audio *(which libshout 2.4.6 requires)*, and libshout sends its password with title updates straight away *(Icecast 2.5 otherwise refuses them)*. Icecast's public directory listing *(YP)* and TLS are left out: the Nginx app serves HTTPS. For the Intel and ARM models *(the ARM ones' build is cross-compiled with clang against Alpine's ARM libraries, and checked under emulation - ffmpeg making an MP3, Icecast serving its status page - but hasn't yet been tried on an ARM NAS)*. The NAS shows an alert when a new Icecast release is out, checked weekly.

## Management page

Icecast's page in the NAS dashboard *(Apps → Icecast)* shows whether it's running *(and the station)*, its version and address; shows, copies or replaces the admin and broadcasting passwords; lists the streams on air with what's playing and their listeners; turns the station from a folder on or off and sets its folder, address, quality, shuffling, name and description, skips to the next track and finds new music; shows what broadcasting software needs; limits access to the Nginx app and sets the listeners allowed at once; restarts Icecast; and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Icecast app

From the project root directory:

```bash
./build.sh icecast
```

This first runs `static/icecast` *(once per version)*, which builds Icecast, ezstream, ffmpeg and the libraries they need from source. The WD bin files will be created in `packages/icecast/`. To update, change the version in `apkg.rc` and `static/icecast/build.sh` *(with the new source's checksum)*. Tests: [`tests/icecast`](../../tests/icecast/README.md).

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
