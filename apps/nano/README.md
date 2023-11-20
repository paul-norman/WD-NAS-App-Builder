# Nano App

Nano is a text editor already present on the WD NAS devices, but it is old *(version 5.2)*. This replaces it with a more modern, statically linked version.

What is the point of this? To test static compilation!

## Building the Nano app

From the project root directory:

```bash
./build.sh nano
```

The WD bin files will be created in `packages/nano/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.