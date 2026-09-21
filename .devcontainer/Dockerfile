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

# Pin Chibi to the reviewed 0.12 tag, verify the exact tarball digest, and
# build a static interpreter with the RLM worker hardening set. The features.h
# patch is the applied flag set; see Experiments/ChibiRLMWorker/README.md for
# what each flag disables. The pinned system dependency is outside SwiftPM SBOM
# coverage.
RUN set -eux; \
    build_dir=/tmp/chibi-build; \
    archive=/tmp/chibi-${CHIBI_VERSION}.tar.gz; \
    mkdir -p "$build_dir"; \
    curl --fail --location --silent --show-error \
        "https://codeload.github.com/ashinn/chibi-scheme/tar.gz/refs/tags/${CHIBI_VERSION}" \
        -o "$archive"; \
    echo "${CHIBI_SHA256}  ${archive}" | sha256sum -c -; \
    tar --extract --gzip --strip-components=1 --directory "$build_dir" --file "$archive"; \
    sed -i \
        -e 's|/\* #define SEXP_USE_NO_FEATURES 1 \*/|#define SEXP_USE_NO_FEATURES 1\n#define SEXP_USE_FLONUMS 1\n#define SEXP_USE_BIGNUMS 1\n#define SEXP_USE_MATH 1\n#define SEXP_USE_RATIOS 0\n#define SEXP_USE_COMPLEX 0|' \
        -e 's|/\* #define SEXP_USE_MODULES 0 \*/|#define SEXP_USE_MODULES 0|' \
        -e 's|/\* #define SEXP_USE_STATIC_LIBS_EMPTY 1 \*/|#define SEXP_USE_STATIC_LIBS_EMPTY 1|' \
        -e 's|/\* #define SEXP_USE_STRICT_TOPLEVEL_BINDINGS 0 \*/|#define SEXP_USE_STRICT_TOPLEVEL_BINDINGS 1|' \
        "$build_dir/include/chibi/features.h"; \
    sed -i 's|^#ifndef SEXP_USE_LIMITED_MALLOC$|#define SEXP_USE_LIMITED_MALLOC 1\n#ifndef SEXP_USE_LIMITED_MALLOC|' \
        "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_NO_FEATURES 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_FLONUMS 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_BIGNUMS 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_MATH 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_RATIOS 0$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_COMPLEX 0$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_MODULES 0$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_STATIC_LIBS_EMPTY 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_LIMITED_MALLOC 1$' "$build_dir/include/chibi/features.h"; \
    grep -q '^#define SEXP_USE_STRICT_TOPLEVEL_BINDINGS 1$' "$build_dir/include/chibi/features.h"; \
    make -C "$build_dir" -j"$(nproc)" SEXP_USE_DL=0 PREFIX=/usr/local chibi-scheme-static; \
    install -Dm755 "$build_dir/chibi-scheme-static" /usr/local/bin/chibi-scheme; \
    install -d /usr/local/share/chibi; \
    install -m644 "$build_dir/lib/init-7.scm" /usr/local/share/chibi/init-7.scm; \
    rm -rf "$build_dir" "$archive"

WORKDIR /workspace
