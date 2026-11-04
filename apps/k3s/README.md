# k3s App

[k3s](https://k3s.io/) is a lightweight, certified Kubernetes distribution: the whole of Kubernetes *(API server, scheduler, kubelet, containerd, CoreDNS, flannel...)* in one program. The app runs a **single-node cluster** on the NAS, natively *(no Docker needed - it has its own containerd)*, for learning Kubernetes, running Helm charts or testing manifests before they go to a bigger cluster.

- `kubectl`, `crictl` and `k3s` are linked into `/sbin`, so `kubectl get pods -A` works over SSH as root. The management page gives a **kubeconfig** for other computers *(the NAS's address on port 6443)* - for `kubectl`, Helm, Lens or the project's Headlamp app.
- It comes with what k3s includes: CoreDNS, the metrics server *(`kubectl top`)* and the local-path storage provisioner *(PersistentVolumeClaims become folders in `_k3s/storage`)*. **Traefik isn't installed** - HTTPS is the Nginx app's job - and **ServiceLB** *(LoadBalancer services on the NAS's own ports)* is off unless switched on on the management page.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_k3s`, and survives reinstalls and removal: the cluster *(`data/`: its database, certificates and images)*, the pods' volumes *(`storage/`)* and logs *(`pod-logs/`)*, the page's settings and `k3s.log` *(kept under 5MB)*. Delete the folder to delete the cluster, or reset it over SSH: `.../k3s/k3s_ctl.sh reset`.
- Images are pulled from the internet *(Docker Hub and others)* as on any cluster.
- k3s doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Memory

**Kubernetes needs memory: k3s itself uses 500-800MB, before any workloads.** A PR4100 or PR2100 comes with 4GB, which is enough for k3s and a few small workloads, but tight alongside other memory-hungry apps *(Jellyfin, the databases, Docker)*; upgraded NASes are comfortable. The Store requires 3GB or more.

The pods may use half of the NAS's memory by default, adjustable on the management page *(25% to 90%)*: the kubelet keeps the rest for the NAS and its other apps, and evicts pods before they'd use it.

## WD's kernel

The NAS's kernel *(4.14)* lacks parts of what Kubernetes needs, so the app adds them as kernel modules, built from WD's own GPL source by `static/k3s` *(as the [Docker app](../docker/README.md) does)*:

- the iptables matches and targets `kube-proxy` and flannel use: `comment`, `multiport`, `statistic`, `mark` / `MARK` and `REJECT`, and the `mangle` table
- `overlay`, so containerd can layer images *(without it, every image is copied whole - slower and much bigger)*

A module only fits the exact kernel it was built for, so the modules are **only loaded on the model and firmware they were built for** *(see `MODELS` and `FIRMWARE` in `static/k3s/build.sh`)*: the PR4100 and PR2100 *(identical kernels)* and the DL4100 *(its own; untested on hardware)*. There's no package for the DL2100 *(WD's GPL archive for it is truncated)* or the ARM models. After a firmware update the modules aren't loaded until the app is rebuilt for it, and k3s can't work without them: the management page says what's missing. If loading a module ever crashes the NAS, it isn't tried again *(a marker file `_k3s/.loading-<module>` is left behind; delete it to try again)*.

It also has only cgroup v1, which Kubernetes has deprecated: since 1.35 the kubelet refuses to start on it unless told otherwise, which the app does *(`failCgroupV1: false`, in a kubelet drop-in it writes at every start, with `failSwapOn: false` for the NAS's swap and the memory reserved for the NAS)*. Kubernetes plans to remove cgroup v1 support altogether in a future release; the app then stays on the last release that has it.

What else differs from a typical k3s install:

- **Networking**: flannel's `host-gw` backend *(one node needs no VXLAN, which the kernel lacks)*, pods in `10.42.0.0/16`, services in `10.43.0.0/16`. **No network policies** *(they need ipset)*.
- k3s's own iptables is used *(`--prefer-bundled-bin`)*: the NAS's lacks the extensions. Kubernetes' and flannel's rules are added alongside the NAS's own and Docker's, and removed when the app stops.
- Stale UDP connections aren't cleaned up when a pod's address changes *(no conntrack netlink - it would change WD's own `nf_conntrack` module)*: rarely noticeable on one node.
- The kubelet's files are in `_k3s/kubelet` and the pods' logs in `_k3s/pod-logs` *(the NAS's `/var` is in RAM)*.

## Ports

- `6443`: the Kubernetes API *(HTTPS; clients authenticate with the kubeconfig's certificate)*
- `10250`: the kubelet *(HTTPS, authenticated)*
- `30000-32767`: NodePort services
- with ServiceLB on, each LoadBalancer service's own ports

## Management page

k3s's page in the NAS dashboard *(Apps → k3s)* shows whether k3s is running and its node ready, its version, whether the kernel has what Kubernetes needs *(and if not, what's missing and why)*, the kubeconfig *(shown or copied)*, and the cluster's pods with their state. It sets the memory the pods may use and ServiceLB, restarts k3s *(the pods keep running)* and shows its latest log lines. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Troubleshooting

- App script log: `/tmp/debug_apkg`
- k3s's log: `/mnt/HD/HD_a2/Nas_Prog/_k3s/k3s.log` *(adjust the volume to match your install)*
- `kubectl describe node`, `kubectl get events -A`

## Building the k3s app

From the project root directory:

```bash
./build.sh k3s
```

This first runs `static/k3s` *(once per version: it downloads WD's GPL source for each model, 1.6GB each, and builds the kernel modules)*. The WD bin files will be created in `packages/k3s/`. To update k3s, change the version in `apkg.rc` and `VERSION` / `K3S_RELEASE` / `K3S_SHA256` *(from the release's `sha256sum-amd64.txt`)* / `K3S_ROOT_VERSION` in `static/k3s/build.sh`. For a new WD firmware, change `FIRMWARE` and `GPL_DATE`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
