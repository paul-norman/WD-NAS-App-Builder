FROM alpine:3.22

# The exporter is an official static program; the run-as helper built alongside it is fully static (musl) too
RUN apk add --no-cache bash binutils build-base wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
