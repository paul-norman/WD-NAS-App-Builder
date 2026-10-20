FROM alpine:3.22

# A fully static (musl) build, depending on none of the NAS's own (old) libraries
RUN apk add --no-cache bash build-base ca-certificates cmake linux-headers perl wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
