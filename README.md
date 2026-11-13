# WD NAS Apps

This is a repository to provide [apps](https://paul-norman.github.io/WD-NAS-App-Builder/) for the WD NAS machines running OS5 *(FW > 5.27.157 - Debian Bullseye)*. It also provides a base for others to build their own apps and Store repos.

## Installation

To make this process as simple as possible for non-expert users, a [Store](https://paul-norman.github.io/WD-NAS-App-Builder/) app has been created that will replace the now end-of-life *(EOL)* WD Store. This offers up-to-date native apps and Docker "Recipes". The original WD Store apps are still available in one of the tabs, but are very out of date.

**Much of the underlying Linux system is now badly out of date**, so a few replacement apps are **strongly recommended to be installed initially** for security reasons:

- [OpenSSH](https://paul-norman.github.io/WD-NAS-App-Builder/openssh/)
- [Python](https://paul-norman.github.io/WD-NAS-App-Builder/python/)
- [PHP](https://paul-norman.github.io/WD-NAS-App-Builder/php/)
- [MariaDB](https://paul-norman.github.io/WD-NAS-App-Builder/mariadb/)

In addition, the [Nginx](https://paul-norman.github.io/WD-NAS-App-Builder/nginx/) app will allow access to all web-based apps via friendly URLs and offer SSL security.

## Building an existing app

To build an existing app, there is a build script in the root directory that will run the process through a Debian 11 (Bullseye) docker container. For example:

```bash
./build.sh <app_name>
```

The WD bin files will be created in `/packages/<app_name>/<version>/*`.

To build for a single model only *(much quicker)*, set `MODEL_OVERRIDE` to its model name, e.g. `MODEL_OVERRIDE=MyCloudPR4100 ./build.sh <app_name>`. Each build replaces that version's release directory, so run a normal build again before publishing all models. A file containing the most recently built version number will also be created in `/packages/<app_name>/latest`.

If you don't have docker installed, see the [guide](docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](docker/WINDOWS.md) for WSL / docker installation.

# Creating a new app

Start from the [template app](apps/template/README.md): a small, working app built the way the project's simpler apps are *(one static program run as its own user, a management page, a site in the Nginx app, update alerts and a test suite)*. Its README says how to copy and rename it, what to change, and where to register the new app.

- `apkg.rc`'s options are explained in the [guide](guides/README.md).
- The app's `build.sh` runs locally from Docker to package it - see the [guide](apps/README.md).
- All the other shell scripts (`apps/<new_app>/*.sh`) run on the WD NAS device itself. See the [overview](guides/README.md) and the [guide](apps/README.md).

## Building statically linked apps

WD NAS devices run a heavily stripped down Debian Bullseye without a package manager, outdated / missing linked libraries and only offer ancient versions of many programs. It's therefore not possible to simply expect many applications to work when built *from* a full Debian machine.

For this reason it's possible to build "statically linked" versions of applications that you want the WD NAS device to run and then include that binary in the app package. These versions have all dependencies bundled with them and require nothing extra.

Creation of these binaries will require an extra build step *(which `./build.sh <app_name>` runs automatically when a matching `static/<app_name>` directory exists, or which can be called manually)*

```bash
./build_static.sh <static_app_name>
```

The statically linked files will be created in `/packages/static/<static_app_name>/<version>/<arch>/*`. A file containing the most recently built version number will also be created in `/packages/static/<static_app_name>/latest`.

Where a program can't work as a fully static binary *(e.g. ValKey 9+, which loads its built-in Lua engine with `dlopen`)*, it is instead built on Debian Bullseye, linked only against glibc. The NAS runs Bullseye's glibc 2.31, so those shared libraries are always present.

`static/docker` is different again: it builds kernel modules that WD's kernel lacks *(`overlay`, `iptable_raw`)* from WD's own GPL source, for one specific firmware version *(see the [Docker app](apps/docker/README.md))*.

Each `static/<static_app_name>/build.sh` must declare the version it builds on its own line as `VERSION=<version>`. A version that has already been built for an architecture is skipped, so bumping `VERSION` is all that's needed to trigger a rebuild *(delete the matching `/packages/static/...` directory to force one)*.

Every file a static build downloads is pinned by its SHA256 and fetched with `static/fetch.sh <url> <file> <sha256>` *(`/data/static/fetch.sh` in the build's container)*: it checks the file, keeps a copy in `/packages/mirror` for later builds, and falls back on the project's mirror when a site is down. Files a Dockerfile builds from are listed in `static/<static_app_name>/downloads` and fetched the same way before the image is built. After a build, each static build's distribution packages are recorded for its sources *(see [CI](ci/README.md), Sources)*.

## Project structure

- `/`
  - `/apps`     - files that build the WD apps
  - `/ci`       - [CI](ci/README.md): GitHub Actions builds and tests each change, releases new app versions and publishes `store.json`
  - `/docker`   - Dockerfiles used to run builds
  - `/guides`   - information that I have found / written
  - `/recipes`  - [Docker recipes](recipes/README.md): compose files for apps best run in Docker, tested on the NAS
  - `/store`    - the [Store and recipe format](store/SPEC.md) (draft): `store.json`, `recipe.json`, their schemas, `tools/build_store.py` (builds `store.json` from the repository) `tools/make_test_repo.sh` (a test repository) - used by the [Store app](apps/store/README.md)
  - `/static`   - build instructions / required files for statically linked programs
  - `/tests`    - [tests](tests/README.md) that run without a NAS, in containers standing in for it *(every app's package, and suites for the Store and the apps with logic of their own)*
  - ---
  - `/packages` - the built apps (static and for devices)

## Inspiration / acknowledgements

This project is building principally upon work done by [Stefan (aka TFL)](https://github.com/stefaang) in the [WDCommunity](https://github.com/WDCommunity/wdpksrc/) Github Repo, but the `helper.sh` script was heavily influenced by Cerberus's App Template from the WD Community Support forums.
