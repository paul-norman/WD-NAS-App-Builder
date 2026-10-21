FROM alpine:3.22

# smartctl, as a fully static (musl) program
RUN apk add --no-cache bash build-base linux-headers wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
