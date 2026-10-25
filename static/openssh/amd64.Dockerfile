# Builds OpenSSH for the NAS, fully static against musl: no part of it depends on the NAS's own libraries, and musl reads
# /etc/passwd and /etc/shadow itself (a static glibc build would load the NAS's NSS libraries for every login)
FROM alpine:3.22

RUN apk add --no-cache bash build-base file linux-headers openssl-dev openssl-libs-static zlib-dev zlib-static wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
