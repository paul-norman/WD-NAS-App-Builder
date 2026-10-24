Everything to request films and TV and have them turn up in your Jellyfin or Plex library - connected to each other for
you, so there's no copying of API keys between settings pages.

- **Seerr**: a friendly page for the household to request films and shows (sign in with your Jellyfin or Plex users).
- **Sonarr** (TV) and **Radarr** (films) find what's requested, have it downloaded, then rename and file it into the
  library - and upgrade it when something better comes along.
- **Prowlarr**: add your indexers (search sites) once, here - Sonarr and Radarr get them all.
- **qBittorrent** downloads; **Bazarr** adds subtitles in your language.
- **Optional**: Lidarr (music), Bookshelf (books and audiobooks), SABnzbd (Usenet, with a provider's account) and
  FlareSolverr (for indexers behind Cloudflare's checks).

One user name and password for every app's page. Downloads and the library share one folder on a share, so finished
downloads are linked into the library rather than copied - no double disk space - and everything can be reached over
SMB too. Point Jellyfin or Plex at its `media` folder.

After installing: add indexers in Prowlarr (they reach the other apps by themselves), then open Seerr and choose your
media server. It uses about **750MB of memory** with the optional apps off (more as libraries grow; FlareSolverr adds
about 500MB).
