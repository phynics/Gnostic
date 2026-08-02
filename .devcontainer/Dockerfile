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
