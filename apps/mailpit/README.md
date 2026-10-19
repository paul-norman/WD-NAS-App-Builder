# Mailpit App

This app creates a Mailpit instance allowing testing of mail sending during development.

- Mailpit's web interface is on port `8025`, and it accepts mail over SMTP on port `1026` *(any username and password; nothing is delivered)*.
- Mailpit's page in the NAS dashboard *(Apps → Mailpit)* shows whether it's running and how many messages it holds, links to it, and can restart it or delete all messages. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Mailpit app

From the project root directory:

```bash
./build.sh mailpit
```

The WD bin files will be created in `packages/mailpit/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
