Google Chrome in a container, for programs on the NAS to drive through the Chrome DevTools Protocol - Patchright,
Playwright, Puppeteer or anything else that speaks it - for pages that only show their content once a browser has run
their JavaScript, logins and clicks, and screenshots.

- **Ready for Patchright**: Chrome runs with a window (on a virtual display) and Patchright's own settings, so a
  program driving it through Patchright is refused as automated by fewer sites.
- **Used by changedetection.io**: with the changedetection.io app installed, it uses this browser by itself - set a
  watch to **Chrome/Javascript** (its Request tab) to load its page here.
- **On the NAS only**: its control port (127.0.0.1:9222) is reachable from the NAS itself, not the network.

It needs the Docker app, and about 1GB of memory while it runs (it's capped there).
