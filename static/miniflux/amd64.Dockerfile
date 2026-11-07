FROM alpine:3.22

# Miniflux is an official static program; the run-as helper built alongside it is fully static (musl) too
RUN apk add --no-cache bash build-base wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
