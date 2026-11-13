# Node.js App

This app provides `node`, `npm`, `npx`, `pnpm` and `pnpx` binaries to allow installing and running Node.js projects directly on the WD NAS device.

- For the Intel and ARM models. On the Intel models it's Node.js's official build. Node.js publishes no 32-bit ARM builds since version 24, so on the ARM models it's built from the same release's source by `static/nodejs` *(fully static, laid out for their kernels' large memory pages, and checked under emulation - crypto, Intl with all of ICU's languages, npm - but not yet tried on an ARM NAS)*. One difference: the ARM build has no `Temporal` *(the new date and time API)* - Node builds that part, written in Rust, for the machine it's built on.
- **pnpm** *(and `pnpx`, plus the short `pn` / `pnx` on the Intel models)* is included. On the ARM models it's pnpm 10, its last plain JavaScript version *(pnpm publishes no native program for 32-bit ARM)*. On the Intel models: since pnpm 11 it's a native program rather than JavaScript *(its npm package only wraps it, and would download it on first use)*, so the build installs it the way pnpm's own install script does - the wrapper package in Node's global `lib/node_modules/pnpm`, with its placeholder `pnpm` replaced by the native program *(checked against npm's published integrity, like the wrapper)*.
- **Corepack** is no longer part of Node.js *(since version 25)*: `npm install -g corepack` installs it, e.g. for **Yarn** *(`corepack yarn install`)*.

A small test server is started on port `30290`, with its output in `test_server.log` in the app's install directory.

The app's page in the NAS dashboard *(Apps → Node.js)* shows the versions of Node.js, npm and pnpm, and the test server's status, with a link to it and a restart button. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Node.js app

From the project root directory:

```bash
./build.sh nodejs
```

This first runs `static/nodejs` *(once per version)*, which downloads Node.js's Intel build and builds the ARM one from its source - about half an hour or more. The WD bin files will be created in `packages/nodejs/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
