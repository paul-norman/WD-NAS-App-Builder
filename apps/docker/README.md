# Docker App

Installs the Docker engine, Docker Compose and the [Portainer](https://www.portainer.io/) web UI from Docker's static binaries, so containers can be run natively on the NAS without an outdated Docker package.

- `docker`, `dockerd`, `docker-compose` and the other binaries are linked into `/sbin`.
- Images, containers and volumes are stored next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_docker` *(linked to `/var/lib/docker`)*, and are kept across reinstalls.
- The WD kernel *(4.14)* has no `overlay` file system, so the app includes an `overlay.ko` kernel module *(plus `iptable_raw.ko`, which Docker 28+ uses to block access to unpublished container ports)*, built from WD's own GPL source by `static/docker`. With it, Docker uses the efficient `overlay2` storage driver.
- A kernel module only fits the exact kernel it was built for, so each model gets its own build, and the modules are **only loaded on the model and firmware they were built for** *(see `MODELS` and `VERSION` in `static/docker/build.sh`)*:

| Model | Modules | Tested on a real NAS |
| ----- | ------- | -------------------- |
| PR4100 | yes | yes |
| PR2100 | yes *(WD's kernel source and config are identical to the PR4100's)* | via the PR4100 |
| DL4100 | yes *(own kernel config)* | no |
| DL2100 | no *(WD's GPL archive is truncated)* | - |
| ARM models | no | - |

- On any other model or firmware *(e.g. after a firmware update)* Docker falls back to the `vfs` storage driver, which works everywhere but makes every image layer a full copy *(much more disk space, slow with large images)*. The log says when this happens; rebuild the app with `VERSION` set to the new firmware *(and its GPL source date)* to restore `overlay2`.
- If loading a module ever crashes the NAS, it isn't tried again: a marker file *(`_docker/.loading-<module>`)* left behind by the crash makes Docker fall back to `vfs`. Delete the marker to try again.
- Each storage driver keeps its own images and containers, so after a switch between `overlay2` and `vfs` the other driver's images and containers aren't visible *(re-pull them; delete the unused `vfs` or `overlay2` directory to free its space)*.
- Docker is limited to half of the NAS's memory *(a third on devices with 1GB or less)*, shared by all containers.
- Portainer is created on first start and is available on port `9000` *(HTTP)* and `9443` *(HTTPS)*. The **Open** button in the NAS web UI redirects to port `9000`.

## Portainer

Portainer has full control of Docker, and through it the NAS itself, so give it a strong admin password. The setup page asks for a **setup token**, which Portainer prints to its log when it starts:

```sh
docker logs portainer 2>&1 | grep -i token
```

Setup must be completed within a few minutes of Portainer starting; if the page says it has timed out, restart Portainer *(`docker restart portainer`)*, which also prints a new token, and try again.

Portainer is only created if no container named `portainer` exists, so upgrading the app doesn't upgrade an existing Portainer. To upgrade it, remove the container *(its settings are kept in the `portainer_data` volume)*, then disable and re-enable the app:

```sh
docker rm -f portainer
```

## Troubleshooting

- App script log: `/tmp/debug_apkg`
- Docker daemon log: `/mnt/HD/HD_a2/Nas_Prog/_docker/docker.log` *(adjust the volume to match your install)*

The daemon can also be controlled directly over SSH with `daemon.sh` in the app's install directory, e.g. `/mnt/HD/HD_a2/Nas_Prog/docker/daemon.sh status`. It accepts `setup`, `start`, `stop`, `shutdown` *(stop and unmount everything)*, `status` and `issetup`.

## Building the Docker app

From the project root directory:

```bash
./build.sh docker
```

The WD bin files will be created in `packages/docker/`. The Docker Compose version is set in `build.sh` and the Portainer version in `start.sh`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
