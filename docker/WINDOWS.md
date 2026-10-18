# Install WSL and Docker on Windows

WSL2 *(Windows Subsystem for Linux)* works on Windows 10 *(version 2004 or later)* and Windows 11, including the Home editions.

## Install WSL2

- Make sure hardware virtualisation *(Intel VT-x / AMD-V, sometimes called "SVM")* is enabled in the computer's BIOS / UEFI settings.
- Launch Powershell as an administrator and run:
	- `wsl --install`
- Restart the computer when asked. Ubuntu finishes installing on the next start and asks you to create a Linux username and password.
- Check that Ubuntu is running under WSL version 2 *(in Powershell)*:
	- Run: `wsl -l -v`

## Access WSL2

To run Ubuntu, just open Powershell *(or [Windows Terminal](https://github.com/microsoft/terminal/releases))*, type `wsl` and press "Enter". You will gain the Ubuntu shell in a few seconds.

To access Ubuntu in Explorer, put: `\\wsl$\Ubuntu\home\<your_username>` in the address bar. You can manage files as normal, but the interface will not automatically refresh and you'll need to refresh *(F5)* to see changes reflected in the files.

**Keep this repository inside the Ubuntu file system** *(e.g. `~/WD-NAS-App-Builder`)* rather than on a Windows drive *(e.g. `/mnt/c/...`)*. Builds are much faster there, and Windows drives mounted into Docker containers have file system quirks.

## Install Docker *(on WSL2)*

These steps follow Docker's [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/). Within WSL Ubuntu:

- Remove any old or unofficial Docker packages *(only those that are installed)*:
	- Run: `sudo apt-get remove -y $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | cut -f1)`
- Add Docker's package repository:
	- Run: `sudo apt-get update`
	- Run: `sudo apt-get install -y ca-certificates curl`
	- Run: `sudo install -m 0755 -d /etc/apt/keyrings`
	- Run: `sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc`
	- Run: `sudo chmod a+r /etc/apt/keyrings/docker.asc`
	- Run all of the lines below together *(as one paste)*:

```bash
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

- Install Docker *(this includes Docker Compose, available as `docker compose`)*:
	- Run: `sudo apt-get update`
	- Run: `sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`
- Start Docker now and whenever WSL starts:
	- Run: `sudo systemctl enable --now docker`
- Allow your user to run Docker without `sudo`:
	- Run: `sudo usermod -aG docker $USER`
	- Run: `exit`, then in Powershell run `wsl --shutdown` and open WSL again for the change to apply
- Check that everything works:
	- Run: `docker run --rm hello-world`
- *Optional, run: `docker login` and add Docker account credentials*

### Troubleshooting

- If `systemctl` reports that systemd isn't running, enable it by adding the following to `/etc/wsl.conf` *(e.g. `sudo nano /etc/wsl.conf`)*, then run `wsl --shutdown` in Powershell and open WSL again:

```ini
[boot]
systemd=true
```

- If Docker fails to start with `iptables` errors *(older WSL kernels)*, switch to the legacy iptables tools and restart Docker:
	- Run: `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy`
	- Run: `sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy`
	- Run: `sudo systemctl restart docker`

## Install Git

Within WSL Ubuntu:

- Run: `sudo apt-get update`
- Run: `sudo apt-get install -y git`
- Edit and run the following:
	- Run: `git config --global user.name "<Your Name>"`
	- Run: `git config --global user.email "<Your Email>"`
