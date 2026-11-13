# Vaultwarden publishes no standalone programs, only images: its official Alpine image holds one static program and the
# web vault, which build.sh copies out. Pinned by digest - keep the tag in step with VERSION in build.sh
FROM vaultwarden/server:1.37.5-alpine@sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191 AS vaultwarden

# The ARM models: Vaultwarden's own ARMv7 program is laid out for 4KB memory pages, and their kernels use larger ones
# (it wouldn't start), so it's built from the same release's source (SHA256 pinned here) - in the toolchain image its own
# Alpine images are built with (Rust, musl, and static OpenSSL, SQLite, PostgreSQL and MySQL client libraries), with
# the same features, linked for 64KB pages. Keep the version and the toolchain (Vaultwarden's rust-toolchain.toml) in
# step with build.sh
FROM ghcr.io/blackdex/rust-musl:armv7-musleabihf-stable-1.99.1@sha256:431ef6d8f87f8888c4c0787ee547de702b6d729acaf14c15705b640e6512da8a AS vaultwarden_armhf

ARG VW_VERSION=1.37.5
ARG VW_SOURCE_SHA256=6be37dcc95b91a058ecbe614f1a7acff68ca8d23dc2c016cec18517c7173e4cc

RUN curl --retry 6 --retry-all-errors -fsSL -o /vaultwarden.tar.gz \
        "https://github.com/dani-garcia/vaultwarden/archive/refs/tags/${VW_VERSION}.tar.gz" && \
    echo "${VW_SOURCE_SHA256}  /vaultwarden.tar.gz" | sha256sum -c - && \
    mkdir -p /app && \
    tar -xzf /vaultwarden.tar.gz -C /app --strip-components=1 && \
    cd /app && \
    rustup target add armv7-unknown-linux-musleabihf && \
    CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS="${CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS} -Clink-arg=-Wl,-z,max-page-size=0x10000 -Clink-arg=-Wl,-z,common-page-size=0x10000 -Clink-arg=-Wl,-z,separate-code" \
    VW_VERSION="${VW_VERSION}" \
    cargo build --locked --release --features sqlite,mysql,postgresql,enable_mimalloc \
        --target armv7-unknown-linux-musleabihf && \
    cp target/armv7-unknown-linux-musleabihf/release/vaultwarden /vaultwarden && \
    rm -rf /app /vaultwarden.tar.gz /usr/local/cargo/registry

FROM alpine:3.22

# The tools bundled with it (sqlite3, argon2 and a run-as helper) are fully static (musl) builds too: gcc builds the
# Intel ones, Zig cross-compiles the ARM ones, and QEMU and Python check the ARM programs
RUN apk add --no-cache bash binutils-arm-none-eabi build-base ca-certificates file python3 qemu-arm unzip wget zig

COPY --from=vaultwarden /vaultwarden /opt/vaultwarden/vaultwarden
COPY --from=vaultwarden /web-vault /opt/vaultwarden/web-vault
COPY --from=vaultwarden_armhf /vaultwarden /opt/vaultwarden/armhf/vaultwarden

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
