FROM alpine:3.22

# Adminer is one PHP file (run by the PHP app's PHP); the run-as helper built alongside it is fully static (musl)
RUN apk add --no-cache bash binutils build-base wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
