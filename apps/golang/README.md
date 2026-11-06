# GoLang App

This app provides the Go compiler to allow running and building of Go files directly on the WD NAS device.

The app's page in the NAS dashboard *(Apps → GoLang)* shows the Go version and its telemetry setting *(with a button to turn it off again, should it ever be turned on)*, and a small test server's status *(port `30289`)*, with a link to it and a restart button. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

Go's telemetry is turned off for `root` when the app starts *(Go only records usage statistics locally by default, and only uploads them after `go telemetry on`)*, and anything already recorded is deleted.

For the Intel and ARM models *(the ARM ones' packages haven't yet been tried on an ARM NAS)*.

## Building the GoLang app

From the project root directory:

```bash
./build.sh golang
```

The WD bin files will be created in `packages/golang/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
