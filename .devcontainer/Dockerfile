FROM swift:6.3.3-noble

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
        'listener 1883 127.0.0.1' \
        'allow_anonymous true' \
        'persistence false' \
        'pid_file /tmp/gnostic-mosquitto.pid' \
        'log_dest stderr' \
        > /etc/mosquitto/gnostic.conf

WORKDIR /workspace
