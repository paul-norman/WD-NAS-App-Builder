#!/bin/sh
# Before removal (the Store's pre_uninstall hook): the optional apps' containers too - Docker Compose only removes those of
# the apps switched on
for container in lidarr bookshelf sabnzbd flaresolverr; do
	docker rm -f "${container}" > /dev/null 2>&1 && echo "Removed ${container}"
done
true
