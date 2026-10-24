#!/bin/sh
# Before a new install (the Store's pre_install hook, also run by setup.sh): Pi-hole needs port 53 (DNS, TCP and UDP) and
# 8053 (its web interface) on the NAS. If something else already has one, the install stops here - rather than Docker
# failing to start it. Run in the recipe's folder, with .env's variables in the environment.

# Whether a port ($2, in hex) is in use for a protocol ($1: tcp - listening - or udp), from the kernel's own tables
in_use() {
	cat /proc/net/$1 /proc/net/${1}6 2>/dev/null | awk -v port="$2" -v protocol="$1" '
		NR > 1 { split($2, local, ":"); if (toupper(local[2]) == port && (protocol == "udp" || $4 == "0A")) found = 1 }
		END { exit !found }'
}

for check in 'tcp 53 0035' 'udp 53 0035' 'tcp 8053 1F75'; do
	set -- ${check}
	if in_use "$1" "$3"; then
		echo "Port $2 ($1) is already used on the NAS - Pi-hole needs it. Is another DNS server (or app) running on it?"
		exit 1
	fi
done
echo "Ports 53 (DNS) and 8053 (web interface) are free"
