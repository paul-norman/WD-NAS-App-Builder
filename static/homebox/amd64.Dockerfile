FROM alpine:3.22

# Homebox is its official release (a Go program: needs only the NAS's own glibc, of any version); the tools built
# alongside it (sqlite3, a run-as helper) are fully static (musl)
RUN apk add --no-cache bash build-base unzip wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
