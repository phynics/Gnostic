FROM swift:6.4.0-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        libcurl4-openssl-dev \
        curl \
        perl \
        libdigest-sha-perl \
        git \
        mosquitto \
        mosquitto-clients \
        ca-certificates \
        guile-3.0 \
    && rm -rf /var/lib/apt/lists/*

ARG NODE_VERSION=22.18.0

RUN node_arch=$(dpkg --print-architecture) \
    && case "$node_arch" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        armhf) node_arch=armv7l ;; \
        *) echo "Unsupported Node.js architecture: $node_arch" >&2; exit 1 ;; \
    esac \
    && curl --fail --location --silent --show-error \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.gz" \
        | tar --extract --gzip --strip-components=1 --directory /usr/local \
    && ln -s /usr/local/bin/node /usr/bin/node \
    && node --version \
    && npm --version

ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
    && if ! id -u vscode >/dev/null 2>&1; then useradd --create-home --shell /bin/bash vscode; fi \
    && chmod -R a+rX "$CARGO_HOME" "$RUSTUP_HOME" \
    && mkdir -p /workspace/.swiftpm-cache \
    && chown -R vscode:vscode /workspace

RUN printf '%s\n' \
        'per_listener_settings true' \
        '' \
        'listener 1883 127.0.0.1' \
        'allow_anonymous true' \
        '' \
        'listener 1884 127.0.0.1' \
        'allow_anonymous false' \
        'password_file /etc/mosquitto/gnostic.passwd' \
        '' \
        'persistence false' \
        'pid_file /tmp/gnostic-mosquitto.pid' \
        'log_dest stderr' \
        > /etc/mosquitto/gnostic.conf \
    && mosquitto_passwd -b -c /etc/mosquitto/gnostic.passwd gnostic-test gnostic-secret \
    && chown mosquitto:mosquitto /etc/mosquitto/gnostic.passwd \
    && chmod 0640 /etc/mosquitto/gnostic.passwd

ARG CHIBI_VERSION=0.12
ARG CHIBI_SHA256=b70a1147bc70a0f90df3fb6081bc99808237fd17a9accf9ee7a2cc20d95a4df0
COPY .devcontainer/patches/chibi-cell-timeout.patch /tmp/gnostic-chibi/.devcontainer/patches/chibi-cell-timeout.patch
COPY Scripts/build-chibi-rlm.sh Scripts/gnostic-rlm-limit-exec.c /tmp/gnostic-chibi/Scripts/

# Pin the patched Chibi build with the same script used for macOS validation.
# The interpreter is outside SwiftPM's dependency and SBOM coverage.
RUN CHIBI_VERSION="${CHIBI_VERSION}" CHIBI_SHA256="${CHIBI_SHA256}" \
        PREFIX=/usr/local bash /tmp/gnostic-chibi/Scripts/build-chibi-rlm.sh \
    && rm -rf /tmp/gnostic-chibi

COPY Scripts/gnostic-rlm-limit-exec.c /tmp/gnostic-rlm-limit-exec.c
COPY Scripts/install-rlm-limit-exec.sh /tmp/install-rlm-limit-exec.sh
RUN bash /tmp/install-rlm-limit-exec.sh \
    && rm /tmp/gnostic-rlm-limit-exec.c /tmp/install-rlm-limit-exec.sh

WORKDIR /workspace
