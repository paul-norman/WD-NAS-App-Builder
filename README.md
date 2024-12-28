# Building WD NAS apps

This is a repository for me to learn how to build apps for the WD NAS machines running OS5 *(FW > 5.27.157 - Debian Bullseye)*.

The goal is to build a [Jellyfin server for WD devices](https://features.jellyfin.org/posts/220/port-to-wd-nas-western-digital-pr4100) without the need for Docker / external packages so that hardware transcoding is possible. Dozens of us are itching to ditch Plex, dozens...

## Building an existing app

To build an existing app, there is a build script in the root directory that will run the process through a Debian 11 (Bullseye) docker container. For example:

```bash
./build.sh <app_name>
```

The WD bin files will be created in `/packages/<app_name>/<version>/*`. A file containing the most recently built version number will also be created in `/packages/<app_name>/latest`.

If you don't have docker installed, see the [guide](docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](docker/WINDOWS.md) for WSL / docker installation.

# Creating a new app

- Copy the `apps/template` app directory and create a new app directory from it in the same parent directory.
  - e.g. `cp -R apps/template apps/new_app`
- Edit the `apps/<new_app>/apkg.rc` file to have a `Package` value which exactly matches the new directory name.
  - e.g. `sed -i 's/Package:.*/Package:\t\t\tnew_app/' apps/new_app/apkg.rc`
  - Other options `apkg.rc` are explained in the [guide](guides/README.md).
- The `apps/<new_app>/build.sh` script runs locally from Docker to package your app. Customise it to your app's needs *(e.g. if you need to package downloaded binaries)* - see [guide](apps/README.md).
  - If you're downloading the application files on the WD NAS device itself, you can leave this file alone.
- All other shell scripts (`apps/<new_app>/*.sh`) run on the WD NAS device itself to perform the actions that are required. See [overview](guides/README.md) and [guide](apps/README.md).

## Building statically linked apps

WD NAS devices run a heavily stripped down Debian Bullseye without a package manager, outdated / missing linked libraries and only offer ancient versions of many programs. It's therefore not possible to simply expect many applications to work when built *from* a full Debian machine.

For this reason it's possible to build "statically linked" versions of applications that you want the WD NAS device to run and then include that binary in the app package. These versions have all dependencies bundled with them and require nothing extra.

Creation of these binaries will require an extra build step *(which can be called manually or from `app/<app_name>/build.sh` - e.g. `apps/nano/build.sh`)*

```bash
./build_static.sh <static_app_name>
```

The statically linked files will be created in `/packages/static/<static_app_name>/<version>/<arch>/*`. A file containing the most recently built version number will also be created in `/packages/static/<static_app_name>/latest`.

## Project structure

- `/`
  - `/apps`     - files that build the WD apps
  - `/docker`   - Dockerfiles used to run builds
  - `/guides`   - information that I have found / written
  - `/static`   - build instructions / required files for statically linked programs
  - ---
  - `/packages` - the built apps (static and for devices)

## Current progress report

- [x] Understand the WD app basics
  - [x] Create a template to expedite future app creation
- [x] Create something new, but simple (`nodejs` app)
- [x] Test wrapping existing Jellyfin Debian builds (`jellyfin` app)
  - [x] Installs
  - [x] Runs
  - [ ] Loads Jellyfin-Web *(truncates HTML output, but does start loading?)*
  - [ ] Use Jellyfin-Ffmpeg *(currently falling back to 3rd party statically linked version)*
- [ ] Learn about building / statically linking
  - [x] Attempt a statically linked build for AMD64 (`nano` app)
  - [ ] Attempt a statically linked build for ARM
    - [Guide](https://jensd.be/1126/linux/cross-compiling-for-arm-or-aarch64-on-debian-or-ubuntu)
    - Create a docker container using `arm-linux-gnueabi-gcc` / `gcc-aarch64-linux-gnu`
- [ ] Complete and test the automatic SSH installation of apps via the `build.sh` script
  - [ ] SSH config to the WD NAS device
  - [ ] Create test file format / helpers
- [ ] Find others willing to help / test *(preferably someone with an ARM based NAS device)*
- [ ] Create some new, really simple, potentially useful, stand-alone apps. *(No need to be novel, perhaps directly out of Entware ipk files to begin with?)*. Some ideas:
  - [x] [Node 23.5.0](https://nodejs.org/dist/v23.5.0/node-v23.5.0-linux-x64.tar.xz)
  - [x] [Go 1.23.4](https://go.dev/dl/go1.23.4.linux-amd64.tar.gz)
  - [x] [phpMyAdmin 5.2.1](https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.tar.gz)
  - [x] [Mailpit 1.21.8](https://github.com/axllent/mailpit/releases/download/v1.21.8/mailpit-linux-amd64.tar.gz)
  - [ ] [PHP 8.4]
  - [ ] [MongoDb 8.0](https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/8.0/main/binary-amd64/mongodb-org-server_8.0.0_amd64.deb)
  - [ ] [Git 2.39](https://bin.entware.net/x64-k3.2/git_2.39.2-1_x64-3.2.ipk)
  - [ ] [Docker 27.4.1](https://download.docker.com/linux/static/stable/x86_64/docker-27.4.1.tgz) / [Docker-Compose 2.32.1](https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-x86_64) / [Portainer 2.25.1](https://github.com/portainer/portainer/releases/download/2.25.1/portainer-2.25.1-linux-amd64.tar.gz)

## Where to find other apps?

There's a list of compiled apps:

- [First Party](https://community.wd.com/t/apps-my-cloud-os5-apps-matrix/286467)
- [Third Party](https://community.wd.com/t/apps-my-cloud-os5-apps-matrix-third-party/286505)

## Inspiration / acknowledgements

This project is building principally upon work done by [Stefan (aka TFL)](https://github.com/stefaang) in the [WDCommunity](https://github.com/WDCommunity/wdpksrc/) Github Repo, but the `helper.sh` script was heavily influenced by Cerberus's [App Template](https://drive.google.com/uc?export=download&id=1Qds0Nh2o4DPlGG6WfIlXLkcChsZlqrp7) from the [WD Community Support forums](https://community.wd.com/t/my-cloud-os5-app-template/286542).