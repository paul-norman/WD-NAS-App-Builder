# Vaultwarden publishes no standalone programs, only images: its official Alpine image holds one static program and the
# web vault, which build.sh copies out. Pinned by digest - keep the tag in step with VERSION in build.sh
FROM vaultwarden/server:1.37.4-alpine@sha256:19ea2b669945d842dadc3d500f2d6a795866a003330f59a47b9634658bae98bb AS vaultwarden

FROM alpine:3.22

# The tools bundled with it (sqlite3, argon2 and a run-as helper) are fully static (musl) builds too
RUN apk add --no-cache bash build-base ca-certificates unzip wget

COPY --from=vaultwarden /vaultwarden /opt/vaultwarden/vaultwarden
COPY --from=vaultwarden /web-vault /opt/vaultwarden/web-vault

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
