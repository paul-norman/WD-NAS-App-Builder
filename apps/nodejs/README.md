# Node.js App

This app provides `node`, `npm`, `npx` and `corepack` binaries to allow installing and running Node.js projects directly on the WD NAS device.

`pnpm` and `yarn` are available through `corepack`, which downloads them on first use *(e.g. `corepack pnpm install`)*.

A small test server is started on port `30290` *(the **Open** button in the NAS web UI redirects to it)*, with its output in `test_server.log` in the app's install directory.

## Building the Node.js app

From the project root directory:

```bash
./build.sh nodejs
```

The WD bin files will be created in `packages/nodejs/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
