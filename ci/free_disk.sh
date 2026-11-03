#!/bin/bash
# Frees disk space on a GitHub-hosted runner (see README.md) by deleting the preinstalled tools CI doesn't use (Android,
# .NET, Haskell, CodeQL, Swift...): about 25 GB more, on top of its ~14 GB. Run by each CI job before it builds:
#
#     ci/free_disk.sh
set -uo pipefail

df -h / | tail -n 1 | awk '{ print "Free before: " $4 }'

sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL \
    /usr/share/swift /usr/local/share/powershell /usr/local/share/chromium /opt/microsoft /opt/google 2>/dev/null
sudo docker image prune -af > /dev/null 2>&1

df -h / | tail -n 1 | awk '{ print "Free after: " $4 }'
