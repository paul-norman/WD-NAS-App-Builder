# Store and recipe format (draft, version 1)

This describes how a repository offers **native apps** (WD `.bin` packages) and **Docker recipes** to the Store app: what it publishes, and what the Store does with it. Any repository can follow it - this project's is one of them.

The key words MUST, SHOULD and MAY mean what they do in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119). Machine-readable versions of the formats are in [`schema/`](schema/): [`store.schema.json`](schema/store.schema.json) and [`recipe.schema.json`](schema/recipe.schema.json) (JSON Schema, draft 2020-12).

- [1. Overview](#1-overview)
- [2. Repositories and `store.json`](#2-repositories-and-storejson)
- [3. Native apps](#3-native-apps)
- [4. Recipes](#4-recipes)
- [5. Requirements](#5-requirements)
- [6. Trust and verification](#6-trust-and-verification)
- [7. What the NAS provides](#7-what-the-nas-provides)
- [8. Versioning of this format](#8-versioning-of-this-format)

## 1. Overview

```
store.json                      <- the repository's catalogue: its apps and recipes (with checksums of every file)
store.json.sig                  <- optional: its signature (section 6)
recipes/
  immich/
    recipe.json                 <- the recipe: what it needs, and the options its install wizard asks for
    compose.yaml                <- a Docker Compose file, using the options as ${VARIABLES}
    description.md              <- shown on the recipe's page in the Store
    icon.svg                    <- optional
    hooks/post_install.sh       <- optional: small steps Compose can't do (hooks/ also holds files they use)
```

- **Native apps** are listed in `store.json` with a download (and checksum) per NAS model. The Store installs them the way the NAS dashboard does.
- **Recipes** are folders with a `recipe.json`. The Store shows their options as a wizard, writes the answers to a `.env` file next to the compose file, and runs `docker compose`. They're declarative: everything the Store does with them is described here, and hooks are only for what's left.

## 2. Repositories and `store.json`

A user adds a repository by its URL. The Store accepts:

- a **GitHub repository URL** - `https://github.com/<owner>/<repo>` (optionally with `/tree/<branch>`): the Store reads `https://raw.githubusercontent.com/<owner>/<repo>/<branch or HEAD>/store.json`
- any **HTTPS URL of a `store.json`**

Only HTTPS is accepted. Relative URLs in `store.json` (icons, recipes, packages) are resolved against `base_url` if it's set, otherwise against the URL `store.json` was read from. A repository SHOULD set `base_url` to an immutable location (a tag or commit, e.g. `https://raw.githubusercontent.com/<owner>/<repo>/<commit>/`), so that the files always match the checksums in the `store.json` being read.

```json
{
	"store_version": 1,
	"name": "WD NAS App Builder",
	"summary": "Native apps and Docker recipes for WD My Cloud OS5 NAS devices",
	"homepage": "https://github.com/paul-norman/WD-NAS-App-Builder",
	"maintainer": "Paul Norman",
	"updated": "2026-10-22T12:00:00Z",
	"base_url": "https://raw.githubusercontent.com/paul-norman/WD-NAS-App-Builder/0123abc/",
	"public_key": "ed25519:MCowBQYDK2VwAyEA...",
	"apps": [ ... ],
	"recipes": [ ... ]
}
```

| Field             |          |                                                                                               |
|-------------------|----------|-----------------------------------------------------------------------------------------------|
| `store_version`   | required | `1` for this document. The Store ignores repositories with a higher major version (section 8) |
| `name`, `summary` | required | Shown in the Store's list of repositories                                                     |
| `homepage`        | optional | The homepage of the Store                                                                     |
| `maintainer`      | optional | The maintainer of the Store                                                                   |
| `updated`         | required | When `store.json` was generated (ISO 8601)                                                    |
| `base_url`        | optional | Base for relative URLs                                                                        |
| `public_key`      | optional | The repository's signing key (section 6)                                                      |
| `apps`            | optional | Native apps (section 3)                                                                       |
| `recipes`         | optional | Recipes (section 4)                                                                           |

Unknown fields MUST be ignored, so that later versions can add some.

**Several repositories** may offer the same app or recipe id *(e.g. a fork)*. The Store lists each repository's entry, labels repositories that share a `name` with their owner *(GitHub)* or host, and records which repository it installed each app and recipe from: only that repository updates it. For an app that keeps its data (`keeps_data`), another repository's entry can replace it *(an update from that repository, which then becomes its source)*. An app installed outside the Store has no source until the Store first updates it. A fork SHOULD use its own `name` and its own signing key.

### Shared fields

Apps and recipes share these:

| Field           |          |                                                                                                                                                                                                                                    |
|-----------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`            | required | For an app, its package name exactly (`Package` in `apkg.rc`, and its folder in `Nas_Prog` - letters, digits, `-` and `_`, e.g. `phpMyAdmin`); for a recipe, lower case letters, digits, `-` and `_`. Unique within the repository |
| `name`          | required | Display name                                                                                                                                                                                                                       |
| `version`       | required | Its version (for apps, `Version` in `apkg.rc`). Compared as dot-separated numbers, then the rest as text                                                                                                                           |
| `summary`       | required | One line                                                                                                                                                                                                                           |
| `description`   | optional | A longer Markdown text, or the relative URL of a Markdown file                                                                                                                                                                     |
| `icon`          | optional | A relative or absolute URL of an SVG or PNG (square, at least 64px)                                                                                                                                                                |
| `categories`    | optional | Any of: `media`, `music`, `photos`, `books`, `backup`, `files`, `monitoring`, `network`, `security`, `development`, `databases`, `productivity`, `home`, `system`                                                                           |
| `homepage`      | optional | The upstream project                                                                                                                                                                                                               |
| `license`       | optional | SPDX identifier of the upstream software, e.g. `AGPL-3.0-only`                                                                                                                                                                     |
| `publisher`     | optional | Who makes the package, when it isn't the repository's maintainer - e.g. `Plex` for Plex's own packages, which the repository lists (its checksums are the repository's) but Plex builds and hosts. The Store says so on the app's page
| `sources`       | optional | URL where the source of the packaged software (and the build) can be found - repositories MUST provide one for GPL / AGPL software                                                                                                 |
| `release_notes` | optional | URL                                                                                                                                                                                                                                |
| `requires`      | optional | Section 5                                                                                                                                                                                                                          |

## 3. Native apps

```json
{
	"id": "navidrome",
	"name": "Navidrome",
	"version": "0.64.2",
	"summary": "Stream your music collection to your browser and phone (Subsonic apps)",
	"icon": "apps/navidrome/web/navidrome.svg",
	"categories": ["music", "media"],
	"homepage": "https://www.navidrome.org/",
	"license": "GPL-3.0-only",
	"sources": "https://github.com/paul-norman/WD-NAS-App-Builder/tree/main/apps/navidrome",
	"release_notes": "https://github.com/paul-norman/WD-NAS-App-Builder/releases/tag/navidrome-v0.64.2",
	"firmware": {
		"min": "5.27.157"
	},
	"data_folder": "_navidrome",
	"keeps_data": true,
	"requires": {
		"ram_mb": 2048
	},
	"packages": [
		{
			"model": "MyCloudPR4100",
			"url": "https://github.com/.../navidrome_0.64.2_MyCloudPR4100.bin",
			"size": 29365368,
			"sha256": "..."
		},
		{
			"model": "MyCloudPR2100",
			"url": "...",
			"size": 29365368,
			"sha256": "..."
		}
	]
}
```

| Field         |          |                                                                                                                                                                                                                                    |
|---------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `packages`    | required | One entry per supported model: `model` (as in `/usr/local/modules/files/model`), `url`, `size` (bytes) and `sha256`                                                                                                                |
| `firmware`    | optional | `min` / `max` firmware versions (`MinFWVer` / `MaxFWVer` in `apkg.rc`)                                                                                                                                                             |
| `data_folder` | optional | The app's folder of data kept outside its install folder (e.g. `_navidrome` in `Nas_Prog`) - mentioned when uninstalling                                                                                                           |
| `keeps_data`  | optional | `true` if the app keeps everything it needs in `data_folder` (or elsewhere outside its install folder), so that it can be removed and installed again without losing anything - which is how the Store updates it. Default `false` |
| `replaces`    | optional | System programs the app takes over (e.g. `["php"]`, `["python3"]`, `["mariadb"]`) - shown as a notice before installing                                                                                                            |
| `web`         | optional | Its web interface, for the Store's "Open" button once installed: the Nginx app's site for it (`nginx.name`), else `port` (and `path`, default `/`) on the NAS - only when it listens on the network by default. After installing or updating it, the Store waits (up to `ready_timeout` seconds, default 300) until `port` - or `local_port`, where it only listens on the NAS itself (e.g. for the Nginx app) - gives any HTTP answer below 500 |

### What the Store does

- **Install**: checks the requirements (section 5) and the model; downloads the model's package into `/usr/local/apps_upload/` (a link to the first volume's `.systemfile/upload` - on disk, not in RAM) under a temporary name, checks its size and SHA256, renames it to the package's file name, then runs `upload_apkg -m -p <file name> -t 2` - the dashboard's own manual install. `/tmp/upload_apkg_status` is `1` once installed. WD's installer checks the package's own signature, firmware versions and free space too, and deletes the file once installed.
- **Installed apps** and their versions are read from `/var/www/xml/apkg_all.xml` (`<name>`, `<show>`, `<version>`, `<enable>`).
- **Update** (a newer `version`): only for apps with `keeps_data: true` - the Store removes the installed app (`del_apkg <id>`, which runs its `stop.sh`, `clean.sh` and `remove.sh`), then installs the new package. `upload_apkg` refuses to install over an installed app (status `4`). Other apps show that an update is available, to be done by hand.
- **Uninstall**: `del_apkg <id>`. The app's `data_folder` is kept; the Store says where it is.

## 4. Recipes

A recipe's entry in `store.json`:

```json
{
	"id": "immich",
	"name": "Immich",
	"version": "3.3.5-1",
	"summary": "Photos and videos: phone backup, albums, search",
	"icon": "recipes/immich/icon.svg",
	"categories": ["photos", "media"],
	"homepage": "https://immich.app/",
	"license": "AGPL-3.0-only",
	"path": "recipes/immich/",
	"files": {
		"recipe.json": "sha256...",
		"compose.yaml": "sha256...",
		"description.md": "sha256...",
		"hooks/post_install.sh": "sha256..."
	},
	"requires": {
		"apps": ["docker"],
		"docker_memory_mb": 6144,
		"storage_driver": "overlay2"
	}
}
```

| Field     |          |                                                                                                                                                     |
|-----------|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `path`    | required | The recipe's folder, relative to `base_url` (or the store's URL), ending in `/`                                                                     |
| `files`   | required | Every file of the recipe the Store downloads, with its SHA256. The Store MUST download only these, and MUST refuse a recipe whose files don't match |
| `version` | required | `<upstream version>-<recipe revision>` is RECOMMENDED                                                                                               |

The other fields repeat `recipe.json`'s, so that the Store can list recipes without downloading them.

### `recipe.json`

```json
{
	"recipe_version": 1,
	"id": "immich",
	"name": "Immich",
	"version": "3.3.5-1",
	"summary": "Photos and videos: phone backup, albums, search",
	"description": "description.md",
	"compose": "compose.yaml",
	"project": "immich",
	"data_folder": "_immich",
	"requires": {
		"apps": ["docker"],
		"docker_memory_mb": 6144,
		"storage_driver": "overlay2"
	},
	"web": {
		"port": 2283,
		"nginx": { "name": "photos", "uploads": true }
	},
	"options": [ ... ],
	"hooks": {
		"post_install": "hooks/post_install.sh"
	},
	"uninstall": {
		"keep": ["UPLOAD_LOCATION"]
	}
}
```

| Field                              |          |                                                                                                                                                                                                                                                                                          |
|------------------------------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `recipe_version`                   | required | `1` for this document                                                                                                                                                                                                                                                                    |
| `id`, `name`, `version`, `summary` | required | As in `store.json`                                                                                                                                                                                                                                                                       |
| `description`                      | optional | Relative path of a Markdown file, shown on the recipe's page                                                                                                                                                                                                                             |
| `compose`                          | required | Relative path of the compose file                                                                                                                                                                                                                                                        |
| `project`                          | required | The Compose project name (`docker compose -p`) - lower case letters, digits, `-` and `_`. MUST be unique among recipes; the compose file SHOULD set the same `name:`                                                                                                                     |
| `data_folder`                      | required | The recipe's folder in the first volume's `Nas_Prog` (e.g. `_immich`). It holds the compose file, `.env` and the Store's records of the install, and is the `{data}` placeholder                                                                                                         |
| `requires`                         | optional | Section 5                                                                                                                                                                                                                                                                                |
| `web`                              | optional | `port` (on the NAS) and `path` (default `/`) of its web interface, for the Store's "Open" link and to wait until it's ready (`ready_timeout`: seconds, default 300); `nginx`: a site for it in the Nginx app, if installed - `name` (the subdomain), and `uploads: true` (no size limit, long time-outs) or `stream: true` (responses passed on as they come) |
| `options`                          | optional | The wizard's questions, in order (below)                                                                                                                                                                                                                                                 |
| `hooks`                            | optional | Scripts for steps Compose can't do (below)                                                                                                                                                                                                                                               |
| `uninstall`                        | optional | `keep`: the keys of `folder` options whose folders are never offered for deletion (e.g. the photos)                                                                                                                                                                                      |

### Options

Each option becomes a variable in `.env`, which `compose.yaml` uses as `${KEY}` (and Compose passes to containers that have `env_file: .env`).

```json
{
	"options": [
		{
			"key": "UPLOAD_LOCATION",
			"type": "folder",
			"label": "Photos and videos folder",
			"help": "On a share, so that the originals can also be reached over SMB. Immich manages what's in it.",
			"default": "{share:Photos}/Immich", "on_share": true, "create": true
		},
		{
			"key": "FACIAL_RECOGNITION",
			"type": "boolean",
			"label": "Face recognition",
			"help": "Finding faces and grouping them into people - the heaviest machine learning on the NAS's CPU.",
			"default": false,
			"values": ["on", "off"],
			"install_only": true
		},
		{
			"key": "TZ",
			"type": "timezone",
			"label": "Time zone",
			"default": "{nas:timezone}",
			"advanced": true
		},
		{
			"key": "DB_PASSWORD",
			"type": "secret",
			"generate": {
				"length": 32
			}
		},
		{
			"key": "DB_DATA_LOCATION",
			"type": "hidden",
			"default": "{data}/postgres",
			"create": true
		},
		{
			"key": "IMMICH_VERSION",
			"type": "hidden",
			"default": "v3"
		}
	]
}
```

Every option has `key` (an environment variable name: `[A-Z][A-Z0-9_]*`) and `type`, and MAY have:

| Field           |                                                                                                                                          |
|-----------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `label`, `help` | Shown in the wizard (`label` is required for options the user sees)                                                                      |
| `default`       | The initial value (placeholders allowed, see below)                                                                                      |
| `required`      | The wizard won't continue while it's empty (default `true` for options the user sees)                                                    |
| `advanced`      | Shown in a collapsed "Advanced" section                                                                                                  |
| `install_only`  | Asked when installing only: afterwards it's the app's own setting (e.g. a hook applied it once), so the Store doesn't offer to change it |

| `type`     | The value                              | Extra fields                                                                                                                                                                                    |
|------------|----------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `string`   | Text                                   | `pattern` (a regular expression it must match), `max_length`                                                                                                                                    |
| `number`   | An integer                             | `min`, `max`                                                                                                                                                                                    |
| `boolean`  | A switch                               | `values`: what's written for on and off (default `["true", "false"]`)                                                                                                                           |
| `choice`   | One of a list                          | `choices`: `[{ "value": "...", "label": "..." }]`                                                                                                                                               |
| `folder`   | A folder path on the NAS               | `on_share` (it must be in a share, not e.g. `Nas_Prog`), `create` (the Store creates it - otherwise it must exist), `empty` (it must be empty or not exist yet), `multiple` and `mount` (below) |
| `port`     | A TCP port                             | `min`, `max`; the Store checks it's free on the NAS                                                                                                                                             |
| `timezone` | A time zone name, e.g. `Europe/London` |                                                                                                                                                                                                 |
| `password` | Text entered by the user, hidden       | `min_length`                                                                                                                                                                                    |
| `secret`   | Generated by the Store, never asked    | `generate`: `length` (default 32) and `charset` (`alnum` - the default - or `hex`)                                                                                                              |
| `hidden`   | A fixed or derived value, never shown  |                                                                                                                                                                                                 |

**Placeholders** in `default`: `{data}` (the recipe's folder, e.g. `/mnt/HD/HD_a2/Nas_Prog/_immich`), `{volume}` (the first volume, e.g. `/mnt/HD/HD_a2`), `{share:<Name>}` (that share's folder - the wizard says when it doesn't exist yet), `{nas:timezone}`, `{nas:hostname}`, `{nas:ip}` and `{option:<KEY>}` (another option's value, defined before it).

**Folders given to a container** (`mount`): some folders can't be written into the compose file in advance - an optional one, or any number of them (`multiple`), e.g. existing photo collections on several shares for Immich to show:

```json
{
	"key": "EXTERNAL_PHOTOS",
	"type": "folder",
	"label": "Existing photo folders",
	"required": false,
	"multiple": true,
	"mount": { "service": "immich-server", "target": "/external", "read_only": true }
}
```

- The Store writes them into `compose.override.yaml` in `{data}`, which Compose reads together with `compose.yaml` by itself - so `docker compose` commands run by hand in that folder use them too. Each folder is a bind mount into `service`, `read_only` if set, at `target` followed by the folder's path on the NAS: relative to the first volume for folders there, otherwise relative to `/mnt` - e.g. `/mnt/HD/HD_a2/Family/Photos` at `/external/Family/Photos`, and `/mnt/USB/USB1_c1/Photos` at `/external/USB/USB1_c1/Photos`. The wizard shows those paths, which the user may need to enter in the app.
- With no folders, nothing is mounted (and `compose.override.yaml` is removed when no option mounts anything). The compose file SHOULD NOT mention these options.
- In `.env`, `multiple` folders are separated by `|`, which folder paths MUST NOT contain.
- A mounted folder MUST already exist and MUST be in a share (as `on_share`, whether set or not), and never in `Nas_Prog` or the volume's hidden system folders: containers usually run as root, and `Nas_Prog` holds other apps' secrets.
- `multiple` requires `mount`; both are only for `folder` options.

Values MUST NOT contain newlines. The Store writes `.env` as `KEY=value` lines, quoting values with spaces or special characters.

### Hooks

Optional POSIX `sh` scripts (BusyBox), for the steps Compose can't do - e.g. a setting in the app's database on a new install. Keys: `pre_install`, `post_install`, `pre_update`, `post_update`, `post_change`, `pre_uninstall`.

- They run as root, in the recipe's folder (`{data}`), with every `.env` variable in their environment plus `STORE_ACTION` (`install`, `update`, `change` or `uninstall`), `STORE_DATA` (the folder), `STORE_VERSION` (the recipe's version) and `STORE_PREVIOUS_VERSION` (on updates).
- `post_install`, `post_update` and `post_change` (after a change of settings) run once `docker compose up -d` has returned - a hook that needs a container to be ready MUST wait for it itself (e.g. its health status), for up to 10 minutes.
- Every file in `hooks/` is part of the recipe's `files` (and downloaded with it): a hook can use others there, e.g. a script it runs. A Store ignores hooks it doesn't know (a newer Store's), so a recipe using them still installs.
- They SHOULD be idempotent. Their output is shown in the Store's log; a non-zero exit stops the install (`pre_*`) or is reported as a warning (`post_*`).

### What the Store does

- **Install**: checks the requirements (section 5); downloads the files listed in `store.json` and checks their SHA256; shows the wizard; validates the answers (on the NAS, whatever the wizard allowed); creates `{data}` (mode `700`) with the compose file (saved as `compose.yaml`), `recipe.json`, `.env` (mode `600`) and `compose.override.yaml` (for `mount` options) in it; creates the `folder` options marked `create`; runs `pre_install`; runs `docker compose -p <project> pull` then `up -d` in `{data}`, showing their progress; runs `post_install`; adds the Nginx site (if `web.nginx` and the Nginx app is installed - section 7), pointing at `web.port` on `127.0.0.1`; waits (if `web`) until `http://127.0.0.1:<port><path>` gives any HTTP answer below 500, for up to `web.ready_timeout` seconds - the same after an update or a change of settings - and says whether it's ready or still starting; records the install in `{data}/.store/installed.json` (the repository, the recipe's version and the answers - except `secret` and `password` values, which stay in `.env` only), and keeps the recipe's files in `{data}/.store/recipe/` (its hooks run from there). Docker Compose runs in `{data}` with `-p <project>` and no `-f`, so that it reads `compose.yaml` and `compose.override.yaml` by itself, as it does for commands typed there by hand. If the install fails part-way, it's undone (`docker compose down`, and `{data}` removed if the Store created it).
- **Existing settings**: when `{data}` already has a `.env` - an earlier install whose folder was kept, or a recipe set up by hand - its values are the wizard's defaults, and `secret` and `password` values are reused (e.g. a database's password, which it was created with). `{data}` is refused if it belongs to an app (it has an `apkg.rc`) or to another recipe.
- **Update** (a newer `version`): downloads and checks the new files; asks only new options (with their defaults), keeping the existing answers; writes `.env` (and `compose.override.yaml`) again; runs `pre_update`, `docker compose pull` and `up -d`, then `post_update`.
- **Change settings**: the options not marked `install_only` can be changed; `.env` (and `compose.override.yaml`) are written again, `docker compose up -d` applies them, then `post_change` runs.
- **Uninstall**: runs `pre_uninstall`, then `docker compose down`, and removes the Nginx site. It then offers to delete `{data}` and the folders of `folder` options marked `create` - except those listed in `uninstall.keep` - each one separately, unticked by default.
- **Manual use**: a recipe is also usable without the Store (e.g. over SSH) - its folder has everything needed, apart from the `.env` the wizard writes. A repository MAY add a `README.md` explaining that.

## 5. Requirements

`requires` (on apps and recipes) lists what must be true before installing. The Store checks each one and explains what's missing, rather than failing part-way.

| Field              |                                                                                                                            |
|--------------------|----------------------------------------------------------------------------------------------------------------------------|
| `models`           | The NAS models it supports (for apps, the models with a package)                                                           |
| `arch`             | `amd64` or `armhf`                                                                                                         |
| `firmware_min`     | The minimum firmware version                                                                                               |
| `ram_mb`           | The NAS's total memory (`MemTotal`)                                                                                        |
| `disk_mb`          | Free space on the first volume                                                                                             |
| `apps`             | Apps that must be installed and running, by `id` (e.g. `["docker"]`, `["nginx"]`)                                          |
| `docker_memory_mb` | The memory Docker may use (the Docker app's memory share)                                                                  |
| `storage_driver`   | `overlay2` if the recipe is impractical on Docker's `vfs` driver (very large images): the Store warns, rather than refuses |

## 6. Trust and verification

Apps and recipes run as root on the NAS, so:

- The Store MUST fetch everything over HTTPS, and MUST check every download against the SHA256 in `store.json`: a package's `sha256` and `size`, and every file in a recipe's `files`.
- **Signing** (RECOMMENDED): a repository publishes an Ed25519 key in `store.json` (`public_key`: `ed25519:` and the base64 SubjectPublicKeyInfo, as `openssl pkey -pubout -outform DER` writes it) and signs every version of `store.json`: `store.json.sig` is the base64 Ed25519 signature of `store.json`'s exact bytes. The Store remembers the key when the repository is added (the default repository's comes with the Store) and from then on MUST refuse a `store.json` that isn't signed by it. A changed key is refused until the user accepts it again, with a warning. The Store verifies with PHP's sodium extension - the NAS's own PHP, or the PHP app's when the NAS's lacks it - or OpenSSL 3 where available; when nothing can check a signature, a signed repository is refused, never trusted.
- Paths (a recipe's `path`, its `files`, `compose`, `description` and hooks, and relative URLs) MUST NOT contain `.` or `..` parts or start with `/`, and the Store MUST check that every file it writes resolves inside the recipe's folder - whatever the schema allowed.
- Adding a repository other than the default one shows a warning: its apps and recipes get full control of the NAS.
- WD's installer also checks each `.bin` package's own signature.

## 7. What the NAS provides

For reference - what the Store relies on, as found on OS5 (firmware 5.33):

|                   |                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Model             | `/usr/local/modules/files/model` (e.g. `MyCloudPR4100`)                                                                                                                                                                                                                                                                                                                                                                           |
| Firmware          | `/etc/version` (e.g. `5.33.102`)                                                                                                                                                                                                                                                                                                                                                                                                  |
| Install a package | `upload_apkg -m -p <file name> -t 2`, with the file in `/usr/local/apps_upload/`; result in `/tmp/upload_apkg_status` (`1` installed, `4` already installed)                                                                                                                                                                                                                                                                      |
| Uninstall         | `del_apkg <id>`                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Installed apps    | `/var/www/xml/apkg_all.xml`                                                                                                                                                                                                                                                                                                                                                                                                       |
| Apps' folders     | `/mnt/HD/HD_a2/Nas_Prog/<id>` (the first volume)                                                                                                                                                                                                                                                                                                                                                                                  |
| Nginx sites       | The Nginx app, if installed, reads an installed recipe's site from its `recipe.json` (`web`: `port`, `path` as the site's start page, `nginx`), so the Store only runs `php <app>/lib/sites.php generate <data>` once the recipe's install record is written or removed. Older Nginx apps are given the site instead: `add-app <data> <name> <target> [<label>] [--uploads] [--stream] [--start=<path>]`, and `remove-app <data> <name>`. `url <data> <name>` prints its address (exit status 1 while it has none, e.g. no domain set); then `sh <app>/nginx_ctl.sh reload`. `<app>` is `Nas_Prog/nginx`, `<data>` is `Nas_Prog/_nginx` |
| Docker            | The Docker app: `docker` and `docker compose`; its storage driver from `docker info --format '{{.Driver}}'`; its memory limit in `/sys/fs/cgroup/memory/docker/memory.limit_in_bytes`                                                                                                                                                                                                                                             |

## 8. Versioning of this format

`store_version` and `recipe_version` are integers. Additions that older Stores can safely ignore (new optional fields) don't change them; anything else increases them. A Store MUST skip a repository whose `store_version`, or a recipe whose `recipe_version`, is higher than it supports, and SHOULD say that the Store needs an update.
