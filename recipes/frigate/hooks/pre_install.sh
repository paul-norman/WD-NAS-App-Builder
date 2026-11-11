#!/bin/sh
# Before a new install (the Store's pre_install hook, also run by setup.sh): Frigate needs ports 8971 (its web
# interface) and 8554 (its RTSP restream) on the NAS - if something else already has one, the install stops here,
# rather than Docker failing to start it. Then Frigate's first settings (config.yml), unless it already has some: so
# that Frigate doesn't write its own defaults when it first starts. Run in the recipe's folder, with .env's variables in
# the environment.

# Whether a TCP port is being listened on, from the kernel's own tables.
#
# $1 port The port, in hex (e.g. 230B for 8971)
#
# Returns 0 if it is
in_use() {
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v port="$1" '
        NR > 1 { split($2, local, ":"); if (toupper(local[2]) == port && $4 == "0A") found = 1 }
        END { exit !found }'
}

for check in '8971 230B' '8554 216A'; do
    set -- ${check}

    if in_use "$2"; then
        echo "Port $1 is already used on the NAS - Frigate needs it. Is another Frigate (or app) running on it?"

        exit 1
    fi
done

echo 'Ports 8971 (web interface) and 8554 (RTSP restream) are free'

config="${CONFIG_LOCATION:-./config}/config.yml"

if [ -f "${config}" ]; then
    echo "Keeping Frigate's existing settings (${config})"

    exit 0
fi

mkdir -p "$(dirname "${config}")"

# The detectors and model sections are rewritten by configure.sh, from the recipe's "Object detection" setting
cat > "${config}" <<'EOF'
# Frigate's settings - change them in Frigate itself (Settings -> Configuration editor), or here (then restart it).
# All of them: https://docs.frigate.video/configuration/reference

mqtt:
  enabled: false

# HTTPS is the Nginx app's (https://cameras.<domain>); on the local network, Frigate is at http://<nas-ip>:8971
tls:
  enabled: false

# The NAS's Intel GPU decodes the cameras' video (VA-API - H.264, and 8-bit H.265)
ffmpeg:
  hwaccel_args: preset-vaapi

# Recordings: kept 7 days where there was motion, alerts and detections 30 days (nothing recorded all the time)
record:
  enabled: true
  continuous:
    days: 0
  motion:
    days: 7
  alerts:
    retain:
      days: 30
  detections:
    retain:
      days: 30

snapshots:
  enabled: true
  retain:
    default: 30

# What's looked for in the cameras' video
objects:
  track:
    - person
    - car
    - cat
    - dog

# Added with Frigate's camera wizard (Settings -> Cameras), or here - see the recipe's README for an example
cameras: {}

# Object detection: written from the recipe's "Object detection" setting (unless that's Manual)
detectors:
  cpu:
    type: cpu
    num_threads: 3
model:
  path: /cpu_model.tflite
  width: 320
  height: 320
version: 0.18-0
EOF

chmod 600 "${config}"
echo "Wrote Frigate's first settings (${config})"
