# Builds WireGuard's userspace programs for the NAS, fully static (musl): wireguard-go (Go), wg (C) and qrencode (C, for
# the management page's QR codes)
FROM golang:1.27.3-alpine

RUN apk add --no-cache bash build-base cmake file linux-headers wget xz

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
