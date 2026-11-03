# CI

GitHub Actions builds and tests every change, and on `main` releases each new app version and publishes `store.json` (what the [Store app](../apps/store/README.md) reads). One workflow does it: [`build-test-release`](../.github/workflows/build-test-release.yml).

| When | What runs |
|---|---|
| A pull request | The apps and recipes the change affects: built and tested. Nothing is released. The packages are kept with the run for a week *(the run's page, Artifacts)*, for trying on a NAS before merging |
| A push to `main` *(a merged pull request)* | The same, then a release for each app version not released yet, then `store.json` |
| By hand *(Actions → build-test-release → Run workflow)* | The apps named *(or `all`)*. On `main`, new versions are released as above; with no apps named, only versions not released yet are built *(e.g. after a failed run)* |

**Nothing is published until the repository variable `RELEASES` is `on`** *(Settings → Secrets and variables → Actions → Variables)*: no releases, no `store.json`, no build cache, no packages kept with a run. Until then every run only builds and tests, and runs on `main` only build what changed *(not every unreleased version)*.

## What a change runs

[`plan.py`](plan.py) works it out from the files changed:

| Changed | Runs |
|---|---|
| `apps/<app>/` *(not its README)* or `static/<app>/` | The app built, its shared package test and its own suite |
| Files every build uses *(`build.sh`, `build_static.sh`, `static/fetch.sh`, `apps/*_helpers.*`, `docker/`, `mksapkg-OS5`, the survey: `ci/survey*.sh`)* | Every app built and tested. Only apps with a new version are released |
| `tests/<suite>/` | That suite, on the app's released package *(no build)* |
| `tests/apps/` | The shared package test of every app; `tests/common/`, `tests/images/`, `ci/tests.conf`: every suite |
| `recipes/<id>/` | Its test through the Store *(`tests/store/run_tests.sh <id>`)* |
| `store/` | The Store's suite *(its tools build the test repositories)* |

Every run also checks `store.json` and the recipes against their schemas, and these rules - a pull request breaking one fails:

- **A changed app or recipe has a newer version**: `Version` in `apps/<app>/apkg.rc`, `version` in `recipes/<id>/recipe.json`. The Store only offers newer versions. For a change to the app alone *(not to what it packages)*, raise its packaging revision: `2.10.7` → `2.10.7-1` → `2.10.7-2`. On `main` *(pushed directly)* it's a warning: the app is built and tested, not released.
- **Every app is in the shared package test** ([`tests/apps/apps.conf`](../tests/apps/apps.conf)).
- **Every download is in the app's sources list** ([`sources/<app>.conf`](sources), see Sources), and every copyleft component there has its source.
- **Every app says whether it keeps its data** (`keeps_data` in [`store/metadata.json`](../store/metadata.json)): `true` if removing it loses nothing *(its data is in `Nas_Prog/_<app>`, or it has none)*, so the Store can update it; `false` if it would.

Each app is a job of its own *(up to 20 at once)*, with a fresh runner's disk *(about 40 GB once [`free_disk.sh`](free_disk.sh) has removed the tools CI doesn't use)* and up to 6 hours. A job: gets the app's package ([`package.sh`](package.sh): built, or fetched from its release when only its tests changed), keeps what a release would publish, gets the other packages its suite uses *(fetched from their releases, or built when this run builds them too)*, then runs the shared package test and its suite ([`job.sh`](job.sh)). [`tests.conf`](tests.conf) lists the suites' commands and the apps they need; apps with a suite on `tests/common` need no line there. A failed job keeps its test logs with the run *(Artifacts: `logs-<app>`)*.

## Releases

One release per app version, tagged `<app>-v<version>` *(e.g. `navidrome-v0.64.2`)*: a package per model, the amd64 bundle *(the packages' contents, which the tests use)*, its sources *(see Sources)* and `SHA256SUMS`. Its notes list the commits to the app since its previous release. Each app is released on its own, so one app's failed test doesn't hold the others back.

**Old releases** are removed after each release run ([`release.py`](release.py) `cleanup`): an app keeps its newest two, and any whose replacement is less than 14 days old *(so a quick run of fixes doesn't remove the last version that ran for a while)*, and never one `store.json` still offers. Their git tags are kept, to rebuild from. Until the repository variable `CLEANUP` is `apply`, it only lists what it would remove *(in the release job's log)*.

**The build cache**: static builds *(e.g. Jellyfin's, Calibre-Web's - some take an hour)* are kept as assets of the `build-cache` release, named after a hash of `static/<app>/`, `build_static.sh` and the survey's scripts, so a build only redoes them when they change. Each keeps its survey *(below)* with it. Nothing there is for installing. Assets no build uses any more are removed with old releases.

## The source mirror

Every file a static build downloads is pinned by its SHA256 and fetched through [`static/fetch.sh`](../static/fetch.sh): it tries a copy kept from an earlier download *(`packages/mirror/<sha256>`, on any machine that builds)*, then the file's own site *(three times)*, then any other sites given for the very same file *(e.g. ffmpeg's: Debian's and Alpine's copies of its release, while they keep that version)*, then this repository's `source-mirror` release - and uses the file only if it matches. A site that's down *(it happens: ffmpeg.org, musl.libc.org)* then doesn't stop a build whose files the mirror has. CI adds each new download to the mirror once it's used *(with the build cache, so once `RELEASES` is on: some downloads are others' programs)*.

Downloads a Dockerfile builds from *(e.g. the ffmpeg stages)* are listed in `static/<app>/downloads` *(`<url> <file> <sha256> [<other url> ...]`)* instead: `build_static.sh` fetches them the same way before building the image, into `static/<app>/.downloads/`, which the Dockerfile copies.

Not through the mirror: Calibre's archive *(checked against the SHA512 Calibre publishes, from GitHub)* and the Docker app's kernel sources *(WD's 1.6 GB GPL archives)*.

## Sources

The packages contain other people's software, much of it under licenses that ask whoever passes it on to offer its source *(GPL, LGPL, AGPL, MPL...)*. So each release carries the sources of everything in its packages under such a license, in `<app>_<version>_sources.tar` *(in parts over 1.9 GB: `cat` joins them)*, listed in `<app>_<version>_SOURCES.md` *(each component, its license, where it came from and its SHA256)*. [`sources.py`](sources.py) `release` gets them, in the app's job, and an app whose sources can't all be got isn't released. What they hold:

| Folder | What | From |
|---|---|---|
| `upstream/` | Each copyleft component the build downloads *(e.g. ffmpeg, Icecast)*, or, for a program included as its makers release it *(e.g. Grafana, Jellyfin, Calibre)*, their source release - the components within it are covered by their makers' own source offers | [`sources/<app>.conf`](sources) |
| `python/`, `npm/` | The copyleft Python and npm packages in the app's bundle *(found from their own metadata)* | PyPI and npm, checked against the digests they publish |
| `debian/`, `alpine/` | The copyleft distribution packages a static build may have linked in *(their static libraries)* or bundles *(shared libraries copied into the app)* | Debian's archives *(or its snapshot archive)*, Alpine's aports at the commit each was built from (from Alpine's GitLab, else its GitHub mirror: GitLab seems to refuse GitHub's runners) *(its APKBUILD read in a container without a network)* - checked against their own checksums |
| *(other folders)* | Sources a static build kept itself *(PHP: every library static-php-cli built in)* | The build |
| `build-files.tar.gz` | This repository's files that built the packages | The commit |

**`sources/<app>.conf`** lists what an app's build files download *(`apps/<app>/build.sh`, `static/<app>/build.sh` and Dockerfiles)*, one line each: the component, its SPDX license, the URL of its source *(with the build's variables, e.g. `${VERSION}`; `url#path` for a file in an archive)* or `-` when none is needed *(a permissive license, or not software)*, and the URL as the build files write it *(or `-` for a component that comes another way, e.g. inside a Docker image)*. A download the list doesn't have fails the run, so a new component can't slip in unlisted: add its line *(and check its license)*.

**The survey** ([`survey.sh`](survey.sh), run by `build_static.sh` after every static build): each stage of the build's Dockerfile is looked at *(`survey_inside.sh`)* for the packages holding static libraries and those whose shared libraries the output bundles, into `packages/static/<app>/<version>/<arch>.sources/distro.tsv`. The copyleft ones get their sources *(Alpine's license field; on Debian, a copyright file naming the GPL or MPL - which takes in some it needn't, rather than miss one)*; GCC's runtime libraries are left out, as their license exempts what's built with them.

## store.json

After the releases, [`publish_store.sh`](publish_store.sh) builds `store.json` for the commit ([`store/tools/build_store.py`](../store/tools/build_store.py)): apps built in this run with their new packages, the others as the `store.json` on `main` lists them *(or from their releases)*, an app whose new version failed still offering its previous one. It's signed with the repository's key *(`store.json.sig`)* and committed to `main` by the bot, only when something in it changed. Its `base_url` is the commit it was built from, so the icons and recipe files always match its checksums. One release job runs at a time *(two merges can't overwrite each other's `store.json`)*; a recipe that failed its tests holds back `store.json` until a run passes.

## Running it locally

The steps are scripts, so they run without GitHub *(Docker and the repository's usual needs)*:

```sh
python3 ci/plan.py --base origin/main               # what a pull request from here would run
python3 ci/plan.py --tests grafana                  # a suite's needs and commands
python3 ci/sources.py check                         # every app's sources list against its build files
python3 ci/sources.py release postgresql /tmp/out   # an app's sources, as its release gets them (app built first)
bash ci/job.sh app navidrome build yes              # one app's job (fetching needs gh, logged in)
python3 ci/release.py cleanup --store store.json    # what cleanup would remove (gh, logged in)
```

## Setting up GitHub

Once, for the repository owner. In the repository's **Settings**:

1. **Secrets and variables → Actions**:
   - Repository secrets: `STORE_SIGNING_KEY` *(the Ed25519 key `store.json` is signed with: `openssl genpkey -algorithm ed25519 -out key.pem`, the whole file)* and `BOT_PRIVATE_KEY` *(the GitHub App's private key, the whole `.pem` file)*.
   - Repository variables: `BOT_CLIENT_ID` *(the App's **Client ID**, on its settings page - not the App ID)*; later `CLEANUP` = `apply`, once the cleanup's listed removals look right.
2. **General → Pull Requests**: tick *Allow auto-merge* and *Automatically delete head branches*.
3. **Rules → Rulesets → New branch ruleset**, for the default branch: *Require a pull request before merging*, and *Require status checks to pass* with the check **result** *(it only appears once the workflow has run)*. In *Bypass list*, add the GitHub App *(it commits `store.json`)* and Repository admin *(you, to push directly)*.

The GitHub App *(the bot)*: your profile's **Settings → Developer settings → GitHub Apps → New GitHub App**, webhook off, repository permissions *Contents* and *Pull requests*: read and write, installed on this repository only. Its token is used for what GitHub's own workflow token can't do: committing to `main` past the branch rules, and *(for the update workflow)* opening pull requests that run this workflow.

A fork works the same with its own key and App: change `repository` in `store/metadata.json` too (see the Store's README, *Forking*).

## Not done yet

- **Sources on pull requests**: only the lists are checked *(every download listed)*; the sources are fetched when an app is released, so a source URL that has moved shows up then *(the app isn't released until it's fixed)*.
- **Go and Rust modules** inside programs aren't scanned: the only one built here *(wireguard-go)* uses permissive modules, and the others are their makers' releases.
- **ARM**: only the apps whose builds already make ARM packages *(Docker, Entware, Node Exporter, phpMyAdmin, Store, Syncthing, Tailscale)* release them; static builds are amd64 only.
