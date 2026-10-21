FROM alpine:3.22

# Loki and Vector are official static programs; the run-as helper built alongside them is fully static (musl) too
RUN apk add --no-cache bash build-base unzip wget

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
