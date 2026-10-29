# Arr stack - Docker recipe

The "arr" apps, set up and **connected to each other**: request films and TV, and have them found, downloaded, renamed and filed into the library your Jellyfin or Plex *(native apps on the NAS)* already shows. It runs in Docker, through the project's [Docker app](../../apps/docker/README.md), from the apps' own images *(LinuxServer.io's for most)*.

| App | What it does | |
|---|---|---|
| [Seerr](https://github.com/seerr-team/seerr) | A page for the household to request films and shows - signing in with their Jellyfin or Plex accounts | always |
| [Sonarr](https://sonarr.tv/) / [Radarr](https://radarr.video/) | TV / films: find what's wanted, have it downloaded, rename and file it into the library, upgrade it later | always |
| [Prowlarr](https://prowlarr.com/) | Indexers *(search sites)*, added once and passed on to the apps above | always |
| [qBittorrent](https://www.qbittorrent.org/) | Downloads torrents | always |
| [Bazarr](https://www.bazarr.media/) | Subtitles for what Sonarr and Radarr have | always |
| [Lidarr](https://lidarr.audio/) | Music: albums by the artists you follow | optional |
| [Bookshelf](https://github.com/pennydreadful/bookshelf) | E-books and audiobooks *(Readarr's continuation, with Hardcover's book data)* | optional |
| [SABnzbd](https://sabnzbd.org/) | Downloads from Usenet *(needs a Usenet provider's account)* | optional |
| [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | Gets Prowlarr past Cloudflare's checks on some indexers | optional |
| [Recyclarr](https://recyclarr.dev/) | Quality rules: the [TRaSH Guides](https://trash-guides.info/)' profiles in Sonarr and Radarr, kept up to date | on by default |

## What's connected for you

The recipe's hook *(`hooks/wire.py`, run after installing, updating or changing settings)* does what's normally an afternoon in settings pages:

- **One user name and password** for every app's web page *(qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, Bookshelf, Bazarr, SABnzbd)*. Changing it in the Store changes it everywhere.
- **The folders**: one data folder on a share with `torrents/`, `usenet/` and `media/{tv,movies,music,books}` - on one file system, so finished downloads are **hard-linked** into the library *(no second copy, and seeding carries on)*: the recommended setup. Everything runs as one user *(ID 84)* in the NAS's `share` group, with group-writable files: the library can be changed over SMB.
- **Or library folders of your own**: TV, film, music and book folders anywhere on the NAS's shares *(e.g. a share of your own: any number each - the first is where new ones go)*, in place of `media/`. Each is mounted only into the apps that need it, at `/media/<its path>` *(e.g. `/mnt/HD/HD_a2/Me/TV` at `/media/Me/TV`)*. Outside the data folder, finished downloads are **copied** into them, not linked: slower to file, and the space is used twice for as long as a torrent seeds. They must be writable by the `share` group *(the setup says so if one isn't - and never changes your folders)*.
- **qBittorrent**: saving to `torrents/`, a category per app, its port. **SABnzbd** *(if on)*: its folders and categories, and the address the apps reach it at.
- **Sonarr, Radarr, Lidarr, Bookshelf**: their library folders, qBittorrent *(and SABnzbd)* as download clients, file renaming on *(or off: names kept as downloaded)*.
- **Films without their own folder** *(off by default)*: Radarr keeps each film in a folder of its own. With this on, a script Radarr runs after each import *(Settings → Connect)* moves the film's files up into the film folder - `Films/Name (2024).mkv` - removes the empty folder, and takes the film off Radarr's list *(its files kept)*, as Radarr would otherwise see it missing and fetch it again. So Radarr won't upgrade or rename those films; Seerr sees them through Jellyfin or Plex. A film whose name is already in the film folder keeps its folder *(and its place in Radarr)*.
- **After a download is filed**: keep seeding *(the default)*, seed for a while *(to a ratio or a number of days, whichever comes first - qBittorrent stops it, then Sonarr or Radarr removes it with its files)*, or don't seed *(stopped as soon as it's complete, and removed once filed)*. Either way only the library's copy is left in the end. Usenet downloads are always removed once filed.
- **Prowlarr**: linked to every library app - **indexers added in Prowlarr reach them all**. FlareSolverr *(if on)* as a proxy for indexers tagged `flaresolverr`.
- **Bazarr**: linked to Sonarr and Radarr, your subtitle language for everything, subtitle sources that need no account.
- **Your media server** *(Plex, Jellyfin or Emby - "Media server" in the settings)*: Sonarr, Radarr and Lidarr tell it about each new, upgraded, renamed or deleted file *(Settings → Connect → "Plex (library updates)")*, so it shows up straight away rather than at the server's next scan. On the NAS by default, at `host.docker.internal` *(the NAS, as the containers see it)* and the server's usual port; or at an address you give. Plex's token is read from Plex on the NAS *(its `Preferences.xml`)*; Jellyfin and Emby need an API key *(Dashboard → API Keys → +)*, and are told of files by their paths on the NAS. The apps test the connection as it's made: if the server doesn't answer *(or the key is wrong)*, the setup says so, and tries again at the next update or change of settings.
- **Quality rules** *(on by default)*: [Recyclarr](https://recyclarr.dev/) puts the [TRaSH Guides](https://trash-guides.info/)' tested profiles in Sonarr and Radarr - **WEB-1080p** and **WEB-2160p** for TV, **HD Bluray + WEB** and **UHD Bluray + WEB** for films - with their custom formats: good sources and release groups preferred, fakes, poor encodes and re-encodes avoided. It syncs them at once, then daily. Seerr's requests use the 1080p ones *(or the 4K ones: "Quality for requests")*. Its settings are `recyclarr/recyclarr.yml` in the recipe's folder - rewritten by the setup, unless you remove its first line to make it your own.
- **Notifications** *(with the [ntfy app](../../apps/ntfy/README.md) on the NAS - "ntfy topic" in the settings, `arr` by default)*: Sonarr, Radarr, Lidarr and Bookshelf send what's filed *(once per release)*, upgraded, failed to download or import, or needs you *(manual import)*, and health problems; Prowlarr its health problems; Seerr new requests *(awaiting approval, or approved)*, what's become available, failures and reported issues. Subscribe to the topic in the ntfy app on your phone *(logged in to the NAS's ntfy)*. Connected with the ntfy app's own token for the NAS's apps, at `host.docker.internal:2586` - so ntfy's "Listen on" must be all addresses *(its default)*. Each app sends a test notification as it's first connected. Installed ntfy later? Save the recipe's settings again *(Store → Arr stack → Settings)*. Seerr's choice of notifications is only set the first time: change it in Seerr *(Settings → Notifications → ntfy)*.
- **Seerr**: linked to Sonarr and Radarr, requesting with the quality rules' profiles - its own short setup then only asks you to sign in with your media server.
- **Switching an optional app off** removes its container and its links *(e.g. from Prowlarr)*.

The API keys are generated by the Store and kept in `.env` *(root only)*. What's left for you: **indexers** in Prowlarr *(which sites to search is your choice)*, **Seerr's setup** *(signing in with Jellyfin or Plex - they need your account, so this can't be done for you)*, and a **Usenet provider** in SABnzbd if you use it.

## Before you start

- **A share for the data**: by default `Media` - create it in the NAS dashboard first *(Shares)*, or choose a folder on another share. Point Jellyfin or Plex at its `media/` folder *(e.g. `Media/media/tv` for TV)*.
- **Memory**: about **800MB** with the optional apps off *(Recyclarr included)*, once running *(more as libraries grow)*; Lidarr, Bookshelf and SABnzbd add about 150-250MB each, FlareSolverr about 500MB. It fits the NAS's standard 4GB.
- **Disk**: the images are about 3GB *(5GB with every optional app)*.
- **Ports**: Seerr 5055, qBittorrent 8090 *(and 6881 for torrents)*, Prowlarr 9696, Sonarr 8989, Radarr 7878, Bazarr 6767, Lidarr 8686, Bookshelf 8787, SABnzbd 8085 - checked before installing.
- **Each app gets a site in the Nginx app** *(if installed)*: `https://seerr.<domain>` - the one for the household - and `radarr.`, `sonarr.`, `prowlarr.`, `bazarr.` and `qbittorrent.<domain>` *(and `lidarr.`, `bookshelf.`, `sabnzbd.` while they're on)*. Each asks for its own login. They're also on the NAS's address, at the ports above.

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Arr stack → Install** - choose the data folder, a user name and password, your media server *(and its key, for Jellyfin or Emby)*, and the optional apps. Then carry on from step 3.

**By hand**, over SSH:

1. Copy this folder to the NAS, e.g. to `Public/arr` over SMB.
2. Over SSH, run:
   ```sh
   sh /mnt/HD/HD_a2/Public/arr/setup.sh
   ```
   It puts `compose.yaml` and a `.env` *(with a generated password - shown once - and API keys)* in `/mnt/HD/HD_a2/Nas_Prog/_arr`, starts the apps and connects them. Change `.env` *(e.g. to switch on Lidarr, or the data folder)* and run it again to apply it.
3. **Prowlarr** *(`http://<nas-ip>:9696`)*: add indexers *(Indexers → Add Indexer)*. They appear in Sonarr, Radarr and the others by themselves.
4. **Seerr** *(`http://<nas-ip>:5055`)*: choose Jellyfin or Plex and sign in - its library and Sonarr / Radarr are then ready. Share its address with the household.
5. **Jellyfin or Plex**: add libraries for `media/tv`, `media/movies` *(and `music`, `books`)* in the data folder.

## Good to know

- **Quality**: with the quality rules on, series and films added from Seerr get the TRaSH Guides' profiles; ones already in Sonarr or Radarr keep theirs *(change them in bulk: Series / Movies → Select → Edit → Quality Profile)*. Switching the rules on later also moves Seerr's requests onto them, unless you chose another profile in Seerr. Recyclarr owns those profiles - changes made to them in Sonarr or Radarr are put back at its next sync; copy one *(Settings → Profiles → clone)* to make your own. With the rules off, Sonarr and Radarr have their default profiles and Seerr requests the 1080p one.
- **Plex, Jellyfin or Emby elsewhere** *(not on the NAS)*: set its address in the settings *(advanced)* - e.g. `http://192.168.1.20:32400`. Plex's token then has to be given: see Plex's "Finding an authentication token" support article.
- **Seeding**: by default qBittorrent keeps seeding finished torrents *(the library copy is a hard link, so it costs no space)*. "After a download is filed" in the Store's settings sets the limits *(they're qBittorrent's own Seeding Limits - changing them there is overwritten by the next change of settings)*. Some trackers expect seeding: check theirs before choosing "don't seed".
- **A VPN for downloads** isn't included: many people route qBittorrent through one *(e.g. with Gluetun and a VPN provider)* - that's a manual change to `compose.yaml`.
- **Updating**: the Store updates the recipe *(newer images)*; by hand, change the images in `compose.yaml` and run `setup.sh` again.
- **Removing it** keeps the data folder *(downloads and library)*; the apps' settings in `Nas_Prog/_arr` go if you choose so.
