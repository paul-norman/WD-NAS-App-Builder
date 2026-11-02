# Vaultwarden publishes no standalone programs, only images: its official Alpine image holds one static program and the
# web vault, which build.sh copies out. Pinned by digest - keep the tag in step with VERSION in build.sh
FROM vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191 AS vaultwarden

FROM alpine:3.22

# The tools bundled with it (sqlite3, argon2 and a run-as helper) are fully static (musl) builds too
RUN apk add --no-cache bash build-base ca-certificates unzip wget

COPY --from=vaultwarden /vaultwarden /opt/vaultwarden/vaultwarden
COPY --from=vaultwarden /web-vault /opt/vaultwarden/web-vault

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
