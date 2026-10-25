# Creating your own SSL certificate

This can be performed on any machine of your choice, it could even be Dockerised. This guide assumes that you are running Ubuntu 26 (either natively or via WSL). If you're using any other *nix operating system, it is assumed that you can probably port this concept to your needs.

Install the tools we will need and create a `dhparam.pem` *(this will take a while!)*:

```bash
sudo apt install libnss3-tools -y
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 4096
```

A program called `mkcert` is used to manage this process:

```bash
cd ~
curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
chmod +x mkcert-v*-linux-amd64
sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
mkcert -install
mkdir ~/certs
```

We can then make our default certificate *(substitute `example.com` for anything you like)*:

```bash
cd ~/certs
mkcert example.com "*.example.com" localhost 127.0.0.1 ::1
```

This will create a wildcard certificate covering the listed domains, but using them will require the correct permissions and moving them to more usable locations:

```bash
sudo chown root:ssl-cert ~/certs/*
sudo chmod 0750 ~/certs/*
sudo mv ~/certs/example.com+4.pem /etc/ssl/certs/star.example.com.pem
sudo mv ~/certs/example.com+4-key.pem /etc/ssl/private/star.example.com.key
```

### Windows WSL extra work...

Install [Chocolaty](/link/2#bkmrk-chocolatey). Open an **admin** Powershell prompt and run *(substituting the correct username)*:

```powershell
choco install mkcert
[System.Environment]::SetEnvironmentVariable('CAROOT', '\\wsl$\Ubuntu\home\<linux username>\.local\share\mkcert\', [System.EnvironmentVariableTarget]::Machine)
exit
```

Reopen another, identical shell:

```powershell
mkcert -CAROOT # Check that this points to Linux
mkcert -install
exit
```

Firefox is awkward and needs us to manually add the root CA. So, in Firefox, visit:

```
Settings > Privacy and Security > Security > View Certificates > Authorities > Import
```

And add the path to the root certificate:

- Linux: `/home/<linux username>/.local/share/mkcert/rootCA.pem`
- Windows: `\\wsl$\Ubuntu\home\<linux username>\.local\share\mkcert\rootCA.pem`

If this doesn't work, copy the rootCA file from WSL into windows, and then add that version of it.

To add a new site *(optional)*, first add it to hosts file, and then:

```bash
cd ~/certs
mkcert example.dev "*.example.dev" localhost 127.0.0.1 ::1
sudo chown root:ssl-cert *
sudo chmod 0750 *
sudo mv ~/certs/example.dev+4.pem /etc/ssl/certs/star.example.dev.pem
sudo mv ~/certs/example.dev+4-key.pem /etc/ssl/private/star.example.dev.key
```

You will still need to [add this certificate to Nginx](README.md) and update your LAN's [DNS resolver](../../recipes/pihole/README.md).
