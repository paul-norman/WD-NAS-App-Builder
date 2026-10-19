# GoLang App

This app provides the Go compiler to allow running and building of Go files directly on the WD NAS device.

Go's telemetry is turned off for `root` when the app starts *(Go only records usage statistics locally by default, and only uploads them after `go telemetry on`)*, and anything already recorded is deleted.

## Building the GoLang app

From the project root directory:

```bash
./build.sh golang
```

The WD bin files will be created in `packages/golang/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
