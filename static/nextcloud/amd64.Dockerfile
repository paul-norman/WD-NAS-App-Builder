FROM alpine:3.22

# Nextcloud is PHP: its release is checked and kept as it is (the app runs it on the PHP app's PHP). The run-as helper is
# built fully static (musl)
RUN apk add --no-cache bash build-base bzip2 wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
