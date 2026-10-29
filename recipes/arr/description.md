Everything to request films and TV and have them turn up in your Jellyfin or Plex library - connected to each other for
you, so there's no copying of API keys between settings pages.

- **Seerr**: a friendly page for the household to request films and shows (sign in with your Jellyfin or Plex users).
- **Sonarr** (TV) and **Radarr** (films) find what's requested, have it downloaded, then rename and file it into the
  library - and upgrade it when something better comes along.
- **Prowlarr**: add your indexers (search sites) once, here - Sonarr and Radarr get them all.
- **qBittorrent** downloads; **Bazarr** adds subtitles in your language.
- **Quality rules**: the TRaSH Guides' tested profiles, so the "best" download is a good one (good sources and release
  groups, no fakes or poor re-encodes) - kept up to date daily by Recyclarr. 1080p or 4K.
- **Your media server** - Plex, Jellyfin or Emby - is told about each new file, so it shows up straight away.
- **Notifications on your phone** with the ntfy app: requests, downloads filed or failed, health problems.
- **Optional**: Lidarr (music), Bookshelf (books and audiobooks), SABnzbd (Usenet, with a provider's account) and
  FlareSolverr (for indexers behind Cloudflare's checks).

One user name and password for every app's page. Downloads and the library share one folder on a share, so finished
downloads are linked into the library rather than copied - no double disk space - and everything can be reached over
SMB too. Point Jellyfin or Plex at its `media` folder - or choose TV, film, music and book folders of your own anywhere
on the NAS's shares (finished downloads are copied into those). Torrents can keep seeding, seed for a while, or be removed
as soon as they're filed, leaving only the library's copy.

After installing: add indexers in Prowlarr (they reach the other apps by themselves), then open Seerr and choose your
media server (Seerr asks you to sign in with it once). It uses about **800MB of memory** with the optional apps off (more as libraries grow; FlareSolverr adds
about 500MB).
