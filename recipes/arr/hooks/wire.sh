#!/bin/sh
# After an install, an update or a change of settings (the Store's post_install, post_update and post_change hooks, also
# run by setup.sh): connects the apps to each other - see wire.py. Run in the recipe's folder, with .env's variables in
# the environment. Python 3 is the NAS's own (or the Python app's)
if ! command -v python3 > /dev/null; then
	echo "python3 isn't available on the NAS: the apps were started, but not connected to each other"
	exit 1
fi
exec python3 "$(dirname "$0")/wire.py"
