# Immich (photos and videos) - Docker recipe

[Immich](https://immich.app/) is a self-hosted replacement for Google Photos / iCloud Photos: phone apps that back up your camera roll automatically, a web interface, albums and sharing, a map, face recognition and search by what's in a photo ("dog on a beach"). It runs in Docker, through the project's [Docker app](../../apps/docker/README.md) - its four containers *(server, machine learning, database, cache)* are Immich's own images.

Tested on a **My Cloud PR4100 with 16GB RAM**, Immich v3.3.5.

## Before you start

- **Memory**: Immich needs about **6GB** for Docker *(4GB without machine learning)*, on top of the NAS's own use. With the NAS's standard 4GB it doesn't fit - the PR4100 / PR2100 take up to 16GB *(2 × 8GB DDR3L SO-DIMM)*. Set the Docker app's memory share on its page accordingly *(e.g. 60% of 16GB)*.
- **Docker's storage**: Immich's images are about 3GB. On a NAS where the Docker app stores images with overlay *(`overlayfs`, or `overlay2` in older versions - see its page)* that's all it takes, plus the compressed downloads containerd keeps; with `native` or `vfs` *(where the overlay module can't be loaded)* each image layer is a full copy, using several times more space - possible, but slower and much bigger.
- **A share for the photos**: by default Immich's own folder is `Photos/Immich` - create a share called **Photos** in the NAS dashboard first *(Shares)*, or set `UPLOAD_LOCATION` to a folder on an existing share *(see below)*. It's for what Immich manages - phone backups and uploads; photos you already have stay where they are *(see [Your existing photos](#your-existing-photos))*.
- **CPU**: the NAS's CPU has no AVX, which Immich's machine learning doesn't need. It's slow, though: the first scan of a large library *(search, text in photos)* can take days - Immich works meanwhile, and new photos are quick.

## Files

- `compose.yaml` - the containers; `example.env` - its settings, for `setup.sh` *(which also writes `compose.override.yaml` for your existing photo folders)*
- `recipe.json`, `description.md`, `icon.svg`, `hooks/post_install.sh` - the [recipe format](../../store/SPEC.md#4-recipes), for the [Store app](../../apps/store/README.md) (its wizard asks the same questions `example.env` holds)
- `setup.sh` - installs it by hand, over SSH (below)

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Immich → Install** - the form asks for the same settings as below, and the Store does the rest *(including the Nginx site)*. Then carry on from step 3.

**By hand**, over SSH:

1. Copy this folder to the NAS, e.g. to `Public/immich` over SMB.
2. Over SSH, run:
   ```sh
   sh /mnt/HD/HD_a2/Public/immich/setup.sh
   ```
   It puts `compose.yaml` and a `.env` *(with a generated database password)* in `/mnt/HD/HD_a2/Nas_Prog/_immich`, creates the folders, downloads Immich's images *(about 3GB, the first time)* and starts it. With the [Nginx app](../../apps/nginx/README.md) installed it also adds `https://photos.<domain>` *(with no size limit for uploads)*.
3. Open `http://<nas-ip>:2283` *(or the Nginx app's address)* **straight away**: the first visit creates Immich's admin user - whoever visits first gets it.
4. In the phone app *(Android or iPhone)*, enter the same address and log in, then turn on backup for the albums you want.

## Your existing photos

Immich has two kinds of photos, and most families use both:

- **Its own folder** *(`UPLOAD_LOCATION`)*: phone backups and uploads from the web page. Immich manages it - its own folder layout and file names, plus the thumbnails and converted videos for *all* photos. Readable over SMB, but don't rename, move or delete anything there.
- **External libraries**: folders you already keep and organise yourself, e.g. one per family member. Immich only reads them - it never moves, renames or deletes anything there, and you keep adding and sorting photos over SMB as before. They get the same timeline, map, search and albums; Immich picks up changes when it rescans *(every day, or **Scan** on the library)*. Deleting or editing those photos in Immich isn't possible - do it in the folder.

To use your existing folders, list them in `.env` *(several separated by `|`)*:

```sh
EXTERNAL_PHOTOS=/mnt/HD/HD_a2/Paul/Photos|/mnt/HD/HD_a2/Jane/Photos
```

and run `setup.sh` again. It gives them to Immich read only, at `/external` followed by their path on the NAS - it prints each one, e.g. `/external/Paul/Photos` *(USB drives: `/external/USB/...`)*. Then, in Immich, **Administration → External Libraries → Create Library**: choose whose photos they are *(the owner - each family member can have their own library)*, **Add path** with the `/external/...` path, and **Scan**. The folders must be on a share *(not in `Nas_Prog`)*.

Before the first scan, check the library's **exclusion patterns** *(in its settings)* cover hidden folders that hold no photos of yours - e.g. thumbnails other software left in the folders. Immich excludes common ones by default.

## Face recognition

**Face recognition** *(finding faces and grouping them into people)* starts **off** with this recipe: it's the heaviest of Immich's machine learning on the NAS's CPU, and not everyone wants it. The rest - search by what's in a photo, text in photos, duplicate detection - is on. To turn it on later: **Administration → Settings → Machine Learning Settings → Facial Recognition**, then **Administration → Job Queues → Face Detection → All** to scan the photos already there. *(To have it on from the start instead, set `FACIAL_RECOGNITION=on` in `.env` before the first run - `setup.sh` only sets this on a new install, before Immich's admin user exists; after that it's Immich's own setting.)*

To change a setting later *(e.g. where the photos go)*, edit `/mnt/HD/HD_a2/Nas_Prog/_immich/.env` and run `setup.sh` again - it keeps the existing `.env`.

## What goes where

| What                                                           | Where                                                                             |                                                                        |
|----------------------------------------------------------------|-----------------------------------------------------------------------------------|------------------------------------------------------------------------|
| Photos and videos *(originals, thumbnails, transcoded videos)* | `UPLOAD_LOCATION` - `/mnt/HD/HD_a2/Photos/Immich`                                 | readable over SMB *(Immich owns the files: don't change them there)*   |
| Your existing photos *(`EXTERNAL_PHOTOS`)*                     | where they already are                                                            | read only for Immich - its thumbnails of them are in `UPLOAD_LOCATION` |
| Database                                                       | `/mnt/HD/HD_a2/Nas_Prog/_immich/postgres`                                         | on the NAS's own volume - Immich doesn't support it on a network share |
| Machine learning models                                        | `/mnt/HD/HD_a2/Nas_Prog/_immich/model-cache`                                      | downloaded by Immich on first use                                      |
| Settings                                                       | `/mnt/HD/HD_a2/Nas_Prog/_immich/.env`, `compose.yaml` and `compose.override.yaml` | root only *(`.env` holds the database password)*                       |

Changes from [Immich's own compose file](https://github.com/immich-app/immich/releases/download/v3.3.5/docker-compose.yml) *(images, versions and pinned digests are unchanged)*: the time zone comes from `TZ` in `.env` instead of a mount of `/etc/localtime`, the NAS's GPU is passed to the server, the database is set up for hard disks *(`DB_STORAGE_TYPE: HDD`)*, the model cache is a folder next to the rest, and the containers' logs are capped at 30MB each *(as the Docker app now does for every container - kept here for Docker installs without that)*. Face recognition starting off is a setting saved in Immich's database by `setup.sh` *(Immich keeps only the settings that differ from its defaults there, so its settings page stays fully editable - unlike its config file option, which makes the page read-only)*.

## Hardware transcoding

Immich converts videos for playback in the browser and the apps. On the CPU that's slow on the NAS; its Intel GPU can do it instead *(the server container has `/dev/dri`)*. To check that Immich's ffmpeg can use it:

```sh
docker exec immich_server /usr/lib/jellyfin-ffmpeg/vainfo
```

Immich's image includes both of Intel's drivers, including the older **i965** one that the NAS's GPU *(Braswell / CherryView)* needs - the listing should name it, with profiles such as H264. Then turn it on in Immich: **Administration → Settings → Video Transcoding Settings → Hardware Acceleration → VAAPI**. If `vainfo` picks the newer driver and fails, add `LIBVA_DRIVER_NAME=i965` to `.env` and run `setup.sh` again; if it still fails, leave transcoding on the CPU.

## Updating, stopping, backups

- **Update** *(within Immich 3.x, set by `IMMICH_VERSION=v3`)*: read Immich's [release notes](https://github.com/immich-app/immich/releases) first, then
  ```sh
  cd /mnt/HD/HD_a2/Nas_Prog/_immich && docker compose pull && docker compose up -d
  ```
  For a new major version *(e.g. v4)*, use that release's compose file - this recipe will be updated for it.
- **Stop / start**: `docker compose stop` / `docker compose start` in the same folder, or in Portainer *(it shows the stack as "immich", created outside Portainer)*. The containers restart with Docker *(and the NAS)* by themselves.
- **Backups**: Immich backs up its database by itself every night, into `UPLOAD_LOCATION/backups`. Back up the whole `UPLOAD_LOCATION` *(photos and those database backups)* somewhere else too - e.g. with the [Kopia app](../../apps/kopia/README.md). The `_immich` folder only needs `.env` *(the database itself is restored from Immich's backups)*.
- **Remove**: `docker compose down` in the folder *(and, with the Nginx app, `php /mnt/HD/HD_a2/Nas_Prog/nginx/lib/sites.php remove-app /mnt/HD/HD_a2/Nas_Prog/_nginx photos` then `sh /mnt/HD/HD_a2/Nas_Prog/nginx/nginx_ctl.sh reload`)*. The photos, database and settings stay until you delete them; your existing photo folders are never touched.
