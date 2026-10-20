# Node.js App

This app provides `node`, `npm`, `npx`, `pnpm`, `pnpx` and `corepack` binaries to allow installing and running Node.js projects directly on the WD NAS device.

- **pnpm** *(and `pnpx`, plus the short `pn` / `pnx`)* is included: since pnpm 11 it's a native program rather than JavaScript *(its npm package only wraps it, and would download it on first use)*, so the build installs it the way pnpm's own install script does - the wrapper package in Node's global `lib/node_modules/pnpm`, with its placeholder `pnpm` replaced by the native program *(checked against npm's published integrity, like the wrapper)*.
- **Yarn** is available through `corepack`, which downloads it on first use *(e.g. `corepack yarn install`)*.

A small test server is started on port `30290`, with its output in `test_server.log` in the app's install directory.

The app's page in the NAS dashboard *(Apps → Node.js)* shows the versions of Node.js, npm and Corepack, and the test server's status, with a link to it and a restart button. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Node.js app

From the project root directory:

```bash
./build.sh nodejs
```

The WD bin files will be created in `packages/nodejs/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
