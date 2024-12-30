FROM alpine:3.21.0

ENV LANG=C.UTF-8

RUN apk upgrade --no-cache -a && \
    apk add --no-cache ca-certificates bash curl wget git build-base pkgconf

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data