FROM alpine:3.22

# Scrutiny's programs and InfluxDB are published static programs; smartctl and the run-as helper are built fully static
# (musl). QEMU's x86-64 emulator runs them as the NAS's processor (no AVX) to check they work there
RUN apk add --no-cache bash build-base curl linux-headers qemu-x86_64 wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
