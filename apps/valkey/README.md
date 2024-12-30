# ValKey App

ValKey is an open-source, fairly licensed, drop-in replacement for Redis. By default it will run on: `0.0.0.0:6379` and can be accessed via the `valkey-cli` *(or `redis-cli`)* command. The config file is available at `/etc/valkey/valkey.conf`.

## Building the ValKey app

From the project root directory:

```bash
./build.sh valkey
```

The WD bin files will be created in `packages/valkey/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.