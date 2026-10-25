# WD NAS Apps

This is a repository to provide apps for the WD NAS machines running OS5 *(FW > 5.27.157 - Debian Bullseye)*. It will also provide a base for others to build their own apps.

To make this process as simple as possible for non-expert users, a [Store](apps/store/README.md) app has been created that will replace the now end-of-life *(EOL)* WD Store *(those apps will still be available)*. This will offer native apps and Docker "Recipes" to provide up-to-date software for this NAS.

Much of the underlying Linux system is now badly out of date, so a few replacement apps are strongly recommended to be installed initially for security reasons:

- [OpenSSH](apps/openssh/README.md)
- [Python](apps/python/README.md)
- [PHP](apps/php/README.md)

In addition, the [Nginx](apps/nginx/README.md) app will allow a

## Building an existing app

To build an existing app, there is a build script in the root directory that will run the process through a Debian 11 (Bullseye) docker container. For example:

```bash
./build.sh <app_name>
```

The WD bin files will be created in `/packages/<app_name>/<version>/*`.

To build for a single model only *(much quicker)*, set `MODEL_OVERRIDE` to its model name, e.g. `MODEL_OVERRIDE=MyCloudPR4100 ./build.sh <app_name>`. Each build replaces that version's release directory, so run a normal build again before publishing all models. A file containing the most recently built version number will also be created in `/packages/<app_name>/latest`.

If you don't have docker installed, see the [guide](docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](docker/WINDOWS.md) for WSL / docker installation.

# Creating a new app

- Copy the `apps/template` app directory and create a new app directory from it in the same parent directory.
  - e.g. `cp -R apps/template apps/new_app`
- Edit the `apps/<new_app>/apkg.rc` file to have a `Package` value which exactly matches the new directory name.
  - e.g. `sed -i 's/Package:.*/Package:\t\t\tnew_app/' apps/new_app/apkg.rc`
  - Other options `apkg.rc` are explained in the [guide](guides/README.md).
- Edit `web/desc.xml` with the app's description in each language *(shown in the NAS web UI; the template has English, French, Spanish and German)*, and use the English text for `Description` in `apkg.rc` too.
- The `apps/<new_app>/build.sh` script runs locally from Docker to package your app. Customise it to your app's needs *(e.g. if you need to package downloaded binaries)* - see [guide](apps/README.md).
  - If you're downloading the application files on the WD NAS device itself, you can leave this file alone.
- All other shell scripts (`apps/<new_app>/*.sh`) run on the WD NAS device itself to perform the actions that are required. See [overview](guides/README.md) and [guide](apps/README.md).

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

## Project structure

- `/`
  - `/apps`     - files that build the WD apps
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
