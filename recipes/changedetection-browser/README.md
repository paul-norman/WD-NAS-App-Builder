# Browser for changedetection.io - Docker recipe

Google Chrome for the [changedetection.io app](../../apps/changedetection/README.md), so that it can watch pages that only show their content once a browser has run their JavaScript - and use browser steps *(logging in, clicking, filling forms)*, screenshots and the visual selector. It runs in Docker, through the project's [Docker app](../../apps/docker/README.md), from Selenium's official image *(for its Google Chrome and virtual display - Selenium itself isn't run)*.

## How it works

- The changedetection.io app drives it through **[Patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python)** rather than Playwright: the same API, but it doesn't switch on Chrome DevTools' Runtime and Console domains, which sites can detect.
- Chrome runs **with a window**, on a virtual display *(Xvfb)* - a headless Chrome is easier for sites to tell apart - and with **Patchright's own Chrome switches**, as Patchright would start it: `--disable-blink-features=AutomationControlled`, and none of the ones that give automation away *(`--enable-automation`...)*.
- Its version matches the app's Patchright *(Chrome 156, Patchright 1.64)*; both are updated together.
- **Its control port is on the NAS itself only** *(`127.0.0.1:9222`, with host networking: Chrome only listens on its own `127.0.0.1`)*. Whoever reaches it controls the browser, so it's not on the network.
- Each start is a fresh profile; Chrome is started again if it stops. Its memory is capped at 1GB.

## Before you start

- The [changedetection.io app](../../apps/changedetection/README.md) and the [Docker app](../../apps/docker/README.md) installed.
- About 1GB of memory for Docker while it runs, and 4GB of disk *(the image)*. Docker's `overlay2` storage driver is recommended: the image is large.

## Files

- `compose.yaml` - the container *(with its start: Xvfb, then Chrome)*; `example.env` - its settings, for `setup.sh`
- `recipe.json`, `description.md`, `icon.svg`, `hooks/post_install.sh` *(has the app use the browser, once it answers)*, `hooks/pre_uninstall.sh` *(the app stops using it)* - the [recipe format](../../store/SPEC.md#4-recipes), for the [Store app](../../apps/store/README.md)
- `setup.sh` - installs it by hand, over SSH (below)

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Browser for changedetection.io → Install**. Once Chrome answers, the changedetection.io app uses it *(it restarts)* - its page shows "Chrome on this NAS".

**By hand**, over SSH: copy this folder to the NAS *(e.g. to `Public/changedetection-browser` over SMB)*, then run:

```sh
sh /mnt/HD/HD_a2/Public/changedetection-browser/setup.sh
```

Then, in changedetection.io, set a watch to **Chrome/Javascript** *(its Request tab)* to load its page in the browser.

## Good to know

- **Removing it**: the Store's uninstall first has the app stop using it *(its watches go back to plain requests)*. By hand: choose "None" on the app's page, then `docker compose down` in `/mnt/HD/HD_a2/Nas_Prog/_changedetection-browser`.
- **Its log**: `docker logs changedetection-browser`.
- **Updating**: the Store updates the recipe together with the app's Patchright *(a newer Chrome)*; by hand, change the image in `compose.yaml` and run `docker compose pull && docker compose up -d` in its folder.
