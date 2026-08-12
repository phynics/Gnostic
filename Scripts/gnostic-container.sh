#!/bin/sh

set -eu

script_path=$(readlink -f "$0")
repo_root=$(CDPATH= cd -- "$(dirname "$script_path")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-podman}
image=${GNOSTIC_IMAGE:-gnostic-dev}
build_root=${GNOSTIC_BUILD_ROOT:-/tmp/gnostic-swift-build/.git/swift-6.3.3-linux/debug}
binary="$build_root/x86_64-unknown-linux-gnu/debug/gnostic"

test -x "$binary" || {
    echo "Gnostic is not built at $binary; run 'make build' in $repo_root" >&2
    exit 2
}

container_args=""
if [ -d "$HOME/.gnostic" ]; then
    container_args="$container_args -v $HOME/.gnostic:/root/.gnostic:ro"
fi

mkdir -p "$HOME/.local/state/gnostic"
exec "$runtime" run --rm -i --network host \
    -v "$repo_root:/workspace:ro" \
    -v "$build_root:/workspace/.build:ro" \
    -v "$HOME/.local/state/gnostic:/root/.local/state/gnostic" \
    $container_args \
    -w /workspace "$image" \
    /workspace/.build/x86_64-unknown-linux-gnu/debug/gnostic "$@"
