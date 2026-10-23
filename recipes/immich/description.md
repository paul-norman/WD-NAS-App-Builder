Immich is a self-hosted replacement for Google Photos and iCloud Photos, running on your NAS.

- **Phone backup**: the Android and iPhone apps back up your camera roll automatically.
- **Browse and share**: a web interface and apps with a timeline, albums, shared albums and links, a map and memories.
- **Search** by what's in a photo ("dog on a beach") and by text in photos, and find duplicates - all on the NAS, with
  nothing sent elsewhere.
- **Your existing photos**: folders you already keep on the NAS (e.g. one per family member) can be shown too, read
  only - Immich never moves or changes them, and you keep organising them as before.
- **Face recognition** is off to start with (it's the heaviest work for the NAS's CPU) - turn it on in Immich's settings
  if you want people grouped.

It needs about **6GB of memory for Docker** (the Docker app's memory share), so most NAS models need a memory upgrade
(the PR4100 / PR2100 take up to 16GB). The first look through a large library is slow on the NAS's CPU and can take days;
Immich works normally meanwhile.

After installing, open Immich straight away: the first visit creates its admin user. Then log in from the phone app with
the same address and turn on backup.
