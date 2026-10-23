# Docker recipes

Some self-hosted apps are best run in Docker, through the project's [Docker app](../apps/docker/README.md), rather than as native apps - usually because they're several services together, or move too fast to repackage. Each recipe here is a compose file tested on a WD My Cloud NAS, with what's needed to run it well there, and a README.

| Recipe                     | What it is                                             | Needs                                         |
|----------------------------|--------------------------------------------------------|-----------------------------------------------|
| [Immich](immich/README.md) | Photos and videos: phone backup, albums, faces, search | ~6GB for Docker (a RAM upgrade on 4GB models) |

The recipes use `docker compose` *(included in the Docker app)*. Their containers also show up in Portainer.

Each recipe follows the [recipe format](../store/SPEC.md#4-recipes): a `recipe.json` describing what it needs and the options its install wizard asks for, so that the [Store app](../apps/store/README.md) can install it without SSH. Each also has a `setup.sh` and a README for installing it by hand.
