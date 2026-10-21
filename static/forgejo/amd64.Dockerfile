FROM alpine:3.22

# Forgejo is an official static program; git (with a minimal curl, for HTTPS remotes) and the run-as helper are built
# fully static (musl)
RUN apk add --no-cache bash build-base ca-certificates linux-headers openssl-dev openssl-libs-static perl wget xz zlib-dev \
	zlib-static

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
