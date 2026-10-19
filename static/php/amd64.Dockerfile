FROM alpine:3.22

# static-php-cli builds fully static (musl) binaries, which depend on none of the NAS's own (old) libraries
RUN apk add --no-cache bash ca-certificates curl wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
