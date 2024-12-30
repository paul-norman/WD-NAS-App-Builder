# Docker

It's a good idea to have the latest versions of Docker and Docker Compose installed, guides:

- [Linux](https://docs.docker.com/desktop/install/linux-install/)
- [MacOS](https://docs.docker.com/desktop/install/mac-install/)
- [Windows](WINDOWS.md) - *(the official [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) gives me nothing but problems!)*

## USEFUL DOCKER COMMANDS

### Images

- List all images: `docker image ls`
- Delete an image: `docker image rm -f <image_id_or_name>`

### Containers

- List running containers: `docker container ls`
- List ALL containers: `docker container ls -a`
- Connect to a running container: `docker exec -it <container_id_or_name> bash`
- Stop all running containers: `docker stop $(docker container ls -q)`
- Remove all unused containers: `docker image prune -a`
- Delete a container: `docker container rm <container_id_or_name>`
- Delete ALL stopped containers: `docker container rm $(docker container ls -aqf status=exited)`

### Volumes

- List all volumes: `docker volume ls`
- Remove a volume: `docker volume rm <volume_id_or_name>`
- Remove all unused volumes: `docker volume prune`

### Network

- List all current networks: `docker network ls`
- Delete a network: `docker network rm <network_id_or_name>`
- Remove all unused networks: `docker network prune`

### Compose

- First / normal build: `docker-compose up --build`
- Start: `docker-compose up`
- Force a rebuild: `docker-compose build --no-cache`
- Force a rebuild of one service: `docker-compose build --no-cache <service_name>`

### Remove EVERYTHING *(Nuclear option when you can't be arsed to debug)*

- `docker system df`
- `docker-compose down`
- `docker stop $(docker ps -q)`
- `docker system prune -a`
- `docker system prune --volumes`
- `docker system df`
