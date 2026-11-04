# Headlamp publishes no standalone server, only images (and desktop apps): its official image holds one static program
# (headlamp-server), the web frontend and its bundled plugins, which build.sh copies out. Pinned by digest - keep the
# tag in step with VERSION in build.sh
FROM ghcr.io/headlamp-k8s/headlamp:v0.46.0@sha256:8a0ef97527544baa2b35825940ddf4db6e2d09c30cd5aa31fd269ff604cc8b75 AS headlamp

FROM alpine:3.22

# The run-as helper bundled with it is a fully static (musl) build too
RUN apk add --no-cache bash build-base file

COPY --from=headlamp /headlamp /opt/headlamp

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
