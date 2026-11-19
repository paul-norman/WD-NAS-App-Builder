# Chrome Browser - Docker recipe

Google Chrome in a container, for programs on the NAS to drive through the **Chrome DevTools Protocol** - [Patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python), Playwright, Puppeteer or anything else that speaks it: pages that only show their content once a browser has run their JavaScript, logins and clicks, screenshots. It runs in Docker, through the project's [Docker app](../../apps/docker/README.md), from Selenium's official image *(for its Google Chrome and virtual display - Selenium itself isn't run)*.

The [changedetection.io app](../../apps/changedetection/README.md) uses it by itself when both are installed.

## How it works

- Chrome runs **with a window**, on a virtual display *(Xvfb)* - a headless Chrome is easier for sites to tell apart - and with **Patchright's own Chrome switches**, as Patchright would start it: `--disable-blink-features=AutomationControlled`, and none of the ones that give automation away *(`--enable-automation`...)*.
- **Patchright is the client's part**: it's the library a program drives Chrome with *(the same API as Playwright)*, and most of its hiding is done there - it doesn't switch on Chrome DevTools' Runtime and Console domains, which sites can detect. Playwright or Puppeteer can drive this Chrome too, without that hiding.
- **Its control port is on the NAS itself only** *(`127.0.0.1:9222`, with host networking: Chrome only listens on its own `127.0.0.1`)*. Whoever reaches it controls the browser - reads its pages, sends requests from the NAS - so it's not on the network.
- One Chrome, shared: each program connects with its own browser contexts *(their own cookies)*, in the same 1GB.
- Each start is a fresh profile; Chrome is started again if it stops.
- Its version matches the changedetection.io app's Patchright *(Chrome 156, Patchright 1.64)*; both are updated together.

## Using it

Connect to `http://127.0.0.1:9222` from the NAS. With Patchright for Python, for example:

```python
from patchright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp("http://127.0.0.1:9222")
    context = browser.new_context()
    page = context.new_page()
    page.goto("https://example.com")
    print(page.content())
    context.close()
```

Close the contexts you open: the browser stays running for the next program. Use a Patchright version made for Chrome 156 *(1.64)*.

## Before you start

- The [Docker app](../../apps/docker/README.md) installed.
- About 1GB of memory for Docker while it runs, and 4GB of disk *(the image)*. Docker's `overlay2` storage driver is recommended: the image is large.

## Files

- `compose.yaml` - the container *(with its start: Xvfb, then Chrome)*; `example.env` - its settings, for `setup.sh`
- `recipe.json`, `description.md`, `icon.svg`, `hooks/post_install.sh` *(has the changedetection.io app use the browser once it answers, if it's installed)*, `hooks/pre_uninstall.sh` *(the app stops using it)* - the [recipe format](../../store/SPEC.md#4-recipes), for the [Store app](../../apps/store/README.md)
- `setup.sh` - installs it by hand, over SSH (below)

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Chrome Browser → Install**. Once Chrome answers, the changedetection.io app *(if installed)* uses it *(it restarts)* - its page shows "Chrome on this NAS". Installing the app later: choose "Chrome on this NAS" on its page.

**By hand**, over SSH: copy this folder to the NAS *(e.g. to `Public/chrome-browser` over SMB)*, then run:

```sh
sh /mnt/HD/HD_a2/Public/chrome-browser/setup.sh
```

## Good to know

- **Removing it**: the Store's uninstall first has the changedetection.io app stop using it *(its watches go back to plain requests)*. By hand: choose "None" on the app's page, then `docker compose down` in `/mnt/HD/HD_a2/Nas_Prog/_chrome-browser`.
- **Its log**: `docker logs chrome-browser`.
- **Updating**: the Store updates the recipe together with the changedetection.io app's Patchright *(a newer Chrome)*; by hand, change the image in `compose.yaml` and run `docker compose pull && docker compose up -d` in its folder.
