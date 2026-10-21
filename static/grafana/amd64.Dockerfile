FROM alpine:3.22

# Grafana is an official static program; the tools built alongside it (sqlite3, a run-as helper) are fully static (musl)
RUN apk add --no-cache bash binutils build-base unzip wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
