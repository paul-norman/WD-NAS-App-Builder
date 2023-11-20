# Install WSL and Docker on Windows

You will need Windows 10/11 Professional *(not Home)* to run this system.

## Install WSL2
- Enable Hyper-V in the computer BIOS
- Enable WSL in Windows
	- Launch Powershell as an administrator
	- Run: `dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart`
	- Run: `dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart`
- Download and Install this [Windows Update](https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi) 
- Set WSL to version 2 *(in Powershell)*:
	- Run: `wsl --set-default-version 2`
- Install Ubuntu *(in Powershell)*:
 	- Run: `wsl --install -d Ubuntu`
- Check Version (22.04) *(in Powershell)*:
	- Run: `wsl -l -v`

## Access WSL2

To run Ubuntu, just open Powershell *(or Terminal)*, type `wsl` and press "Enter". You will gain the Ubuntu shell in few seconds.

To access Ubuntu in Explorer, put: `\\wsl$\Ubuntu-22.04\home\<your_username>` in the address bar. You can manage files as normal, but the interface will not automatically refresh and you'll need to refresh *(F5)* to see changes reflected in the files.

## Install Docker *(on WSL2)*

- Launch WSL
 	- Launch Powershell / [Windows Terminal](https://github.com/microsoft/terminal/releases)
	- Run: `wsl`
- Within WSL Ubuntu:
	- Run: `sudo apt-get remove docker docker-engine docker.io containerd runc`
	- Run: `sudo apt-get update`
	- Run: `sudo apt-get upgrade -y`
	- Run: `sudo apt-get install -y ca-certificates curl gnupg lsb-release`
	- Run: `sudo mkdir -p /etc/apt/keyrings`
	- Run: `curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg`
	- Run: `echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu   $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null`
	- Run: `sudo apt-get update`
	- Run: `sudo apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin`
	- Run: `sudo service docker start`
	- Run: `sudo usermod -aG docker $USER`
	- Run: `sudo systemctl enable docker.service`
	- Run: `sudo systemctl enable docker.socket`
	- Run: `sudo docker run hello-world`
	- Run: `sudo curl -L https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose`
	- Run: `sudo chmod +x /usr/local/bin/docker-compose`
	- Run: `docker-compose -v`
	- If using Ubuntu > 20.10:
		- Run: `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy`
		- Run: `sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy`
	- Run: `exit`
	- *Optional, run: `docker login` and add Docker account credentials*

## Install Git

- Launch WSL
 	- Launch Powershell / [Windows Terminal](https://github.com/microsoft/terminal/releases)
	- Run: `wsl`
- Within WSL Ubuntu:
  - Run: `sudo apt-get update`
  - Run: `sudo apt-get upgrade -y`
  - Run: `sudo apt-get install -y git`
  - Edit and run the following:
    - Run: `git config --global user.name "<Your Name>"`
	- Run: `git config --global user.email  "<Your Email>"`
