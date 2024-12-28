# Node.js App

This app provides `node`, `npm`, `npx`, `pnpm` and `corepack` binaries to allow installing and running Node.js projects directly on the WD NAS device.

## Building the Node.js app

From the project root directory:

```bash
./build.sh nodejs
```

The WD bin files will be created in `packages/nodejs/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.