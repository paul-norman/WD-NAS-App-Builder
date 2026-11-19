Google Chrome for the changedetection.io app, so that it can watch pages that only show their content once a browser
has run their JavaScript - and use browser steps (logging in, clicking, filling forms), screenshots and the visual
selector.

- **Set up for you**: once it's installed, the changedetection.io app uses it by itself. In changedetection.io, set a
  watch to **Chrome/Javascript** (its Request tab) to load its page in the browser.
- **Harder to spot**: changedetection.io drives it through Patchright rather than Playwright, and Chrome runs with a
  window (on a virtual display) and Patchright's own settings - so fewer sites refuse it as automated.
- **On the NAS only**: its control port is reachable from the NAS itself, not the network.

It needs the changedetection.io app and the Docker app, and about 1GB of memory while it runs (it's capped there).
