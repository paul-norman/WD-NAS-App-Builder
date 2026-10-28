# Store App

An unofficial Store for WD NAS systems: it installs **native apps** *(WD `.bin` packages)* and **Docker recipes** from repositories - this project's, and any others you add - from a page in the NAS dashboard, without SSH. Repositories follow the [Store and recipe format](../../store/SPEC.md).

While it's on, the Store **is the dashboard's Apps page**: the list of installed apps down the side is replaced by the Store, full width *(see [The Apps page](#the-apps-page))*. Its tabs:

- **Installed**: every app on the NAS *(this project's, WD's and any installed by hand)* and every recipe. An app's page has **Configure** *(its own page, as the side list previously opened it)*, a **Running** switch *(the NAS's own on/off switch)*, and Update and Remove.
- **Apps**: install, update and remove native apps. The Store downloads the package for your NAS model, checks it against the checksum in the repository's catalogue, and installs it with the NAS's own installer *(the same one as the dashboard's manual install)*.
- **Recipes**: apps that run in Docker *(e.g. [Immich](../../recipes/immich/README.md))*. Each recipe's settings are a short form *(e.g. which share the photos go in)*: the Store writes them to a `.env` file next to the recipe's compose file, starts it with `docker compose`, and - with the [Nginx app](../nginx/README.md) installed - gives it an HTTPS address. Settings can be changed later, and recipes updated or removed, from the same page.
- **Manual install**: installing an app from its package file *(`.bin`)* on your computer, with the NAS's own installer - as the Apps page's "install an app manually" did.
- **WD Store**: Western Digital's own app store, as the Apps page offered it.
- **Repositories**: the list of catalogues the Store reads. New versions are looked for by themselves: every night, and when the page opens if it's been over an hour *(Refresh does it now)*. This project is there by default; others can be added by their address *(a GitHub repository, or the HTTPS address of a `store.json`)*.

The Store works only when its page is used: nothing runs in the background. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*. **Activity** shows the log of the latest install, update or removal.

## Trust

Apps and recipes run as root, so the Store is careful about where they come from:

- Everything is downloaded over **HTTPS only** *(redirects to plain HTTP are refused)*.
- Every download is checked against the **SHA256 checksum** in the repository's catalogue - packages, and every file of a recipe - and refused if it doesn't match.
- A repository can **sign** its catalogue *(Ed25519)*. Its key is remembered when the repository is added, and from then on a catalogue that isn't signed by that key is refused. If the key changes, the page shows the new key's fingerprint and waits for you to accept it. *(Checking signatures needs PHP's sodium extension: the NAS's own PHP may not have it, in which case the Store uses the [PHP app](../php/README.md)'s PHP. Without either, a signed repository is refused rather than trusted.)*
- Adding a repository other than this project's asks you to confirm that you trust it, and its apps and recipes are labelled as third-party.
- A recipe's files can't reach outside its folder, and the folders a recipe is given must be on a share - never `Nas_Prog`, where other apps keep their secrets.
- WD's installer also checks each package's own signature.

## Apps

- Some apps are listed by a repository but **made by someone else** - e.g. **Plex Media Server**, Plex's own package for each WD model, downloaded from Plex. Their page says so; the repository vouches for the package's checksum.
- **Updating** an app means removing the installed version and installing the new one - the NAS's installer won't install over an app. The Store only does this for apps that keep their data outside their install folder *(e.g. `Nas_Prog/_jellyfin`)*, which this project's apps do; for others it shows that an update is available. If the NAS's installer fails after the old version was removed, the Store puts the old version back and starts it *(it keeps its files, as hard links, until the new one is in)*, and says why the installer failed. Updating or removing the Nginx app while the dashboard is reached through it asks first, as the page loses its connection: start it from `http://<nas-ip>/` instead.
- **Removing** an app keeps its data folder; the Store says where it is. An app that another installed app needs *(its `InstDepend`)* can't be removed until that one is.
- **Removing the Store** *(Installed → Store → Remove)* brings back the NAS's own Apps page. Everything it installed stays installed, and its settings *(e.g. your repositories)* stay in `Nas_Prog/_store` for if it's installed again. To turn it off for a while instead, untick **Running**.

## Repositories

Removing a repository only removes it from the Store's list *(and its cached catalogue)*. Apps and recipes installed from it stay installed and keep working, and a recipe's settings can still be changed and it can be removed *(from the copy of the recipe kept in its folder)* - they just get no updates. Adding the repository again picks them up where they were, updates included. Its signing key is pinned afresh when it's added again.

## The Apps page

The Store replaces the dashboard's Apps page with its own copy of it *(`wd/app.php`, bind-mounted over WD's read-only `/usr/local/modules/web/pages/addons/app.php` when the Store starts - at boot, or when it's switched on)*. WD's file is never changed: switching the Store off, removing it or updating it puts WD's page back. The copy keeps everything of WD's that its app store needs *(its scripts, dialogs and manual install)*, without the list down the side.

If the Store's page ever fails to load there, the Apps page says so and how to get WD's back over SSH:

```sh
umount /usr/local/modules/web/pages/addons/app.php
```

## Recipes

- A recipe's settings, compose file and data go in its own folder in `Nas_Prog` *(e.g. `Nas_Prog/_immich`)*, root-only. Passwords and generated secrets are kept only in its `.env`.
- **Changing settings** rewrites `.env` and applies it *(`docker compose up -d`)*. Settings that only make sense at install time *(e.g. Immich's face recognition default)* become the app's own settings afterwards.
- **Updating** a recipe asks only for its new settings, if any.
- **Removing** a recipe stops and removes its containers and its Nginx site. You choose which folders are deleted with it *(none by default)*; folders the recipe marks as yours - e.g. Immich's photos - are never offered. If its own folder is kept, installing it again reuses its settings *(e.g. its database password, which the database was created with)*. A recipe set up by hand *(e.g. with its `setup.sh`)* is picked up the same way.
- If an install fails part-way, it's undone.

## Several repositories offering the same app *(e.g. a fork)*

A fork of this project usually offers the same apps, under the same ids. The Store keeps them apart:

- Each app is listed once per repository. Repositories with the same name are labelled with their owner *(e.g. `WD NAS App Builder (paul-norman)` and `WD NAS App Builder (someone)`)*.
- The Store remembers which repository it installed each app and recipe from, and only that one updates it. Another repository's page for it says where it came from; for apps that keep their data, it offers **Switch to this repository** - an update from that repository, after which its updates come from there.
- An app installed by hand *(Manual install, or over SSH)* has no repository: any repository can update it, the Installed tab shows the newest version on offer, and its page lists the others. The update you choose sets where its updates come from.
- A recipe is installed from one repository at a time *(its folder is the same)*: another repository's page for it points to its page there.

## Forking

To publish your own repository from a fork:

1. Set your repository's details in [`store/metadata.json`](../../store/metadata.json) *(`repository`: its name, summary, homepage and maintainer)* - a different name saves users from telling the two apart by owner.
2. Sign it with your own key *(`openssl genpkey -algorithm ed25519 -out key.pem`, then `--sign-key key.pem`)*. Never reuse this project's.
3. Build `store.json` with [`store/tools/build_store.py`](../../store/tools/build_store.py), pointing `--package-url` *(and `--base-url`, `--release-url`, `--sources-url`)* at your fork's releases and files.
4. Users add it by its GitHub address *(Repositories)* - next to this project's, or instead of it.

The Store's own default repository *(added on a first install)* is `STORE_DEFAULT_REPO` in [`lib/store.php`](lib/store.php). A fork that ships its own Store build can change it to its own; one that doesn't leaves its users with this project's repository, plus whichever they add.

## Where things are

| What | Where |
|---|---|
| Repositories, cached catalogues and icons, the last job's log | `Nas_Prog/_store` *(root only)* |
| Packages while they're installed | `/usr/local/apps_upload` *(the dashboard's own upload folder, on the disk - deleted once installed)* |
| Each recipe | `Nas_Prog/<its folder>`: `compose.yaml`, `.env`, `compose.override.yaml` *(folders chosen in its settings)*, `.store/` *(the recipe's files and the install record)* |

## Testing a repository

`store/tools/make_test_repo.sh` builds a repository from your built packages and the recipes, in a folder any HTTPS web server can serve - e.g. a site of the Nginx app on the NAS itself *(Nginx app → Sites, pointed at the folder; PHP off)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh store             # and any apps to offer
store/tools/make_test_repo.sh /path/to/share/repo https://repo.<your domain>/
```

Then add `https://repo.<your domain>/store.json` in the Store *(Repositories)*. Add `--sign-key key.pem` *(an Ed25519 key: `openssl genpkey -algorithm ed25519 -out key.pem`)* to sign it.

The Store's own tests run without a NAS: see [`tests/store`](../../tests/store/README.md).

## Building the Store app

From the project root directory:

```bash
./build.sh store
```

The WD bin files will be created in `packages/store/`. The Store is plain PHP *(no binaries)*, so it's built for every model.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
