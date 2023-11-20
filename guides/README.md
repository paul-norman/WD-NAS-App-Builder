# WD NAS Device Development Guides

Included in this folder are the WD dev guides that they released to assist developers with creation of apps for WD NAS Devices.

`MyCloud_OS5_AppGuide_Oct2020.pdf` focuses on the toolchain required to build apps for WD NAS devices. It is designed to help app developers package their apps suitably.

`MyCloud_OS5_AppStructure_Oct2020.pdf` focuses on the creation of the wrapper that is uploaded to WD NAS devices which contains the app *(or instructions to download it)*. This guide will give an overview of this file.

## Overview

WD calls their packaging management system "Apps Package", and it allows special archived files to be uploaded and installed onto the WD NAS devices. It creates these packages using a program called `mksapkg`. Since there were two MyCloud operating systems *(OS3 and OS5)*, we will refer to this tool as `mksapkg-OS5`.

## Packaging Command

The raw apps are packaged using a single command from within the directory that we wish to package:

```bash
cd /path/to/my_app
mksapkg-OS5 -E -s -m <model_name>
```

Where the `<model_name>` is the model name of a supported WD NAS device:

| Model Name      | Product Code | Architecture |
| --------------- | ------------ | ------------ |
| WDCloud         | MirronMan    | armhf        |
| WDMyCloud       | Glacier      | armhf        |
| WDMyCloudMirror | GrandTeton   | armhf        |
| WDMyCloudEX2100 | Yosemite     | armhf        |
| WDMyCloudEX4100 | YellowStone  | armhf        |
| MyCloudEX2Ultra | RangerPeak   | armhf        |
| MyCloudPR4100   | BlackCanyon  | amd64        |
| MyCloudPR2100   | BryceCanyon  | amd64        |
| WDMyCloudDL4100 | Sprite       | amd64        |
| WDMyCloudDL2100 | Aurora       | amd64        |

## Package Contents

The folder that is packaged **must** contain certain files. Further files are allowed, but optional. Most of the files are written in shell script. WD NAS devices use [BusyBox v1.30.1](https://en.wikipedia.org/wiki/BusyBox) *(`/bin/sh`)* as their shell, so while mostly compatible with [Bash](https://en.wikipedia.org/wiki/Bash_(Unix_shell)) commands, it lacks come functionality.

To enable SSH *(Secure SHell)* access to your WD NAS device, follow [this guide](https://support-eu.wd.com/app/answers/detailweb/a_id/21699/~/my-cloud%3A-enable-ssh-%28secure-shell%29-on-a-pr4100) on their support site.

### `apkg.rc`

The `apkg.rc` file is a config file containing information for the Apps Package system. It must contain the following fields:

| Field Name         | Example                      | Description                                                  | Required? | Restrictions                                 |
| ------------------ | ---------------------------- | ------------------------------------------------------------ | :-------: | -------------------------------------------- |
| Package:           | template                     | The app name                                                 | y         | no spaces, max length 32                     |
| Version:           | 0.0.1                        | The app version                                              | y         | max length 32, [0-9]{1,2}(\.[0-9]{1,2}){0,5} |
| Packager:          | PDN                          | The packager's name                                          | n         | max length 64                                |
| Email:             | packager@email.com           | The creator / packager's email *(for support)*               | n         | max length 64                                |
| Homepage:          | https://github.com/repo/name | The app's homepage                                           | n         | max length 256                               |
| Description:       | A brief app description      | A brief app description                                      | n         | max length 256                               |
| Icon:              | logo.svg                     | A logo to show in the web UI                                 | n         |                                              |
| AddonShowName:     | Template						| The Web UI app name                                          | y         | max length 64                                |
| AddonIndexPage:    | index.php                    | The web UI configure source *(/var/www/template/index.php)*  | n         |                                              |
| AddonUsedPort:     |                              | The port used by the app                                     | n         |                                              |
| AddonDefaultPort:  |                              |                                                              | n         |                                              |
| AddonDefaultGroup: |                              | The system group that the app should run under               | n         |                                              |
| AddonDefaultUser:  |                              | The system user that the app should run as                   | n         |                                              |
| InstDepend:        |                              | Any other apps that this app depends upon for installation   | n         |                                              |
| InstConflict:      |                              | Any other apps that this app conflicts with at installation  | n         |                                              |
| StartDepend:       |                              | Any other apps that this app depends upon at startup         | n         |                                              |
| StartConflict:     |                              | Any other apps that this app conflicts with at startup       | n         |                                              |
| CenterType:        | 0                            | Embed app configuration UI: 0 - own page, 1 - web UI page    | y         | Enum(0, 1)                                   |
| UserControl:       | 1                            | Controllable by: 0 - any user, 1 - admin only                | y         | Enum(0, 1)                                   |
| MinFWVer:          | 5.27.157                     | The minimium compatible firmware version                     | n         | max length 32, [0-9]{1,4}(\.[0-9]{1,4}){0,5} |
| MaxFWVer:          |                              | The maximium compatible firmware version                     | n         | max length 32, [0-9]{1,4}(\.[0-9]{1,4}){0,5} |
| IndividualFlag:    | 1                            | The web UI will show some notice information for apps        | n         | Enum(0, 1)                                   |
| Hidden:            | off                          | Should the app appear for users                              | n         | Enum(off, on)                                |

### `install.sh`

Copies files and installs the app to an appropriate directory.

### `init.sh`

Creates necessary symbolic links for installed app before being executed *(usually to /usr/bin or /usr/sbin)*. If necessary, restore configuration files previously backed-up through `preinst.sh`.

### `clean.sh`

Remove all links or files created by `init.sh`.

### `preinst.sh`

Runs some commands when re-installing an app *(e.g. backup configuration files to other places)*.

### `remove.sh`

Removes the installed app completely.

### `start.sh`

Starts the app daemon.

### `stop.sh`

Stops the app daemon.

## Action Chains

The above scripts are called in chains when certain actions are taken in the Web UI. These are all called from the path where they are installed *(and this path is passed in as an input parameter)*, apart from when uploading the app, in that case it is called from a separate upload path *(and passed that path in addition to the install location)*.

### 1. Installation

1. $UPLOAD_PATH/`install.sh` $UPLOAD_PATH $INSTALL_PATH
2. $INSTALL_PATH/`init.sh` $INSTALL_PATH
3. $INSTALL_PATH/`start.sh` $INSTALL_PATH

### 2. Removal

1. $INSTALL_PATH/`stop.sh`
2. $INSTALL_PATH/`clean.sh`
3. $INSTALL_PATH/`remove.sh` $INSTALL_PATH

### 3. Re-installation

1. $INSTALL_PATH/`stop.sh`
2. $INSTALL_PATH/`clean.sh`
3. $INSTALL_PATH/`preinst.sh` $INSTALL_PATH
4. $INSTALL_PATH/`remove.sh` $INSTALL_PATH
5. $UPLOAD_PATH/`install.sh` $UPLOAD_PATH $INSTALL_PATH
6. $INSTALL_PATH/`init.sh` $INSTALL_PATH
7. $INSTALL_PATH/`start.sh` $INSTALL_PATH

### 4. Enable

1. $INSTALL_PATH/`start`.sh

### 5. Disable

1. $INSTALL_PATH/`stop`.sh

## Config Web Page

If the app has a web UI configuration page *(`AddonIndexPage` in `apkg.rc`)* or a logo *(`Icon` in `apkg.rc`)*, these files will be searched for in a standard path location: `/var/www/<app>` *(where `<app>` is `Package` in `apkg.rc`)*.

The logo file, index page, and any other files needed for configuration purposes must be moved to the `/var/www/<app>` directory as part of the installation. These files are typically stored in a `web` directory within the package itself and symlinked to this location by the `init.sh` script.

PHP 7.4 is installed on the WS Nas devices providing execution of PHP files, though HTML files may also be used.

### Redirects

It's fairly common for an app to have its own webserver listening on a port, in this case it's common to use a very small PHP index page to redirect to the correct port *(in combination with `CenterType: 0`)*:

```php
<?php header('Location: http://'.$_SERVER['HTTP_HOST'].':1234/'); ?>
```

Where `1234` should be substituted for the correct port for the specific app.

### CGI

Common Gateway Interface (CGI) may be used to handle configuration requests *(often using Python)*. These files are typically stored in a `cgi-bin` directory within the package itself.

### Multi-Lingual App Description

Place a `desc.xml` in `/var/www/app_name` folder. For example, the Icecast app uses:

```xml
<?xml version="1.0" encoding="utf-8"?>
<config>
	<en-US>A free server software for streaming multimedia.</en-US>
	<cs-CZ>Bezplatný serverový software pro vysílání multimediálního obsahu.</cs-CZ>
	<de-DE>Eine kostenlose Serversoftware für das Streaming von Multimedia-Inhalten.</de-DE>
	<es-ES>Software gratuito de servidor para transmitir contenido multimedia.</es-ES>
	<fr-FR>logiciel serveur gratuit de diffusion de contenus multimédias.</fr-FR>
	<hu-HU>Ingyenes kiszolgálószoftver a multimédiás tartalmak adatfolyam útján történő továbbításához.</hu-HU>
	<it-IT>software server gratuito per lo streaming dei contenuti multimediali.</it-IT>
	<ja-JP>マルチメディア ストリーミング用の無料サーバー ソフトウェア。</ja-JP>
	<ko-KR>멀티미디어 스트리밍을 위한 무료 서버 소프트웨어.</ko-KR>
	<no-NO>Et gratis serverprogram for direkteavspilling av multimedia.</no-NO>
	<nl-NL>Een gratis serversoftware voor het streamen van multimedia.</nl-NL>
	<pl-PL>Bezpłatne oprogramowanie serwerowe do strumieniowych transmisji danych multimedialnych.</pl-PL>
	<pt-BR>Um software de servidor gratuito para fazer transmissão multimídia.</pt-BR>
	<ru-RU>Бесплатное серверное программное обеспечение для потокового воспроизведения мультимедиа.</ru-RU>
	<sv-SE>En gratis serverprogramvara för strömning av multimedia.</sv-SE>
	<tr-TR>Multimedya akışına yönelik ücretsiz bir yazılım.</tr-TR>
	<zh-CN>用于流式传输多媒体的免费服务器软件。</zh-CN>
	<zh-TW>用於串流多媒體的免費伺服器軟體。</zh-TW>
</config>
```