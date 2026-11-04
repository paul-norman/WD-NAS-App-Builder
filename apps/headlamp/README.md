# Headlamp App

[Headlamp](https://headlamp.dev/) is a web UI for Kubernetes *(a Kubernetes SIG project)*: workloads, their logs and events, shells into containers, editing resources as YAML, Helm releases, and the cluster's metrics. The app runs it natively on the NAS *(no Docker)* for the [k3s app](../k3s/README.md)'s cluster, which it finds by itself - install k3s first.

- It's at `https://headlamp.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically; Nginx calls it `localhost`, the only name Headlamp accepts when it listens on the NAS itself only - its protection against DNS rebinding)*, and at `http://<nas-ip>:4466` on the local network unless limited to the Nginx app on the management page.
- **It asks for a token.** Headlamp is given the cluster's address and certificate authority but no credentials of its own, so whoever opens it must log in with a token: the one of the `headlamp-admin` service account *(cluster-admin)* that the app adds to the cluster, which the management page shows, copies or replaces. The browser keeps it until you log out.
- The account is added through k3s's own manifests folder *(`_k3s/data/server/manifests/headlamp-admin.yaml`)*, so k3s applies it whenever it runs - also when Headlamp is installed before the cluster has started.
- It runs as its own `headlamp` user *(created by the app, ID 94)*, not as root.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_headlamp`, and survives reinstalls and removal: its home *(`home/`, with the plugins you add in `home/plugins`)*, the page's settings, the generated `kubeconfig` *(no credentials)* and `headlamp.log` *(warnings only, kept under 1MB)*.
- It's the official server, web frontend and bundled plugins *(Prometheus charts)*, copied out of Headlamp's official image by `static/headlamp`. Headlamp doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Removing it for good

The `headlamp-admin` account stays in the cluster when the app is removed *(removal can't tell an update from a removal, and an update mustn't change the token)*. To remove it too, over SSH:

```sh
kubectl delete -f /mnt/HD/HD_a2/Nas_Prog/_k3s/data/server/manifests/headlamp-admin.yaml
rm /mnt/HD/HD_a2/Nas_Prog/_k3s/data/server/manifests/headlamp-admin.yaml
```

## Management page

Headlamp's page in the NAS dashboard *(Apps → Headlamp)* shows whether it's running, whether it has found the k3s app's cluster *(and whether k3s is running)*, its addresses, and the token *(shown, copied or replaced)*. It limits Headlamp to the Nginx app, restarts it, and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Headlamp app

From the project root directory:

```bash
./build.sh headlamp
```

This first runs `static/headlamp` *(once per version)*. The WD bin files will be created in `packages/headlamp/`. To update, change the version in `apkg.rc` and `static/headlamp/build.sh`, and the image's tag and digest in `static/headlamp/amd64.Dockerfile`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
