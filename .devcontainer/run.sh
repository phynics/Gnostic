#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
runtime=${CONTAINER_RUNTIME:-}
build_dir=${BUILD_DIR:-$("$root_dir/Scripts/gnostic-build-path.sh" build-dir)}
build_lock_timeout=${BUILD_LOCK_TIMEOUT:-1800}
container_timeout=${CONTAINER_TIMEOUT:-3600}

case $container_timeout in
    ''|*[!0-9]*|0) echo "CONTAINER_TIMEOUT must be a positive integer, got: $container_timeout" >&2; exit 2 ;;
esac

# Runtime bind mounts require absolute host paths. Lock the canonical build
# directory so aliases of the same path still serialize.
mkdir -p "$build_dir"
build_dir=$(CDPATH= cd -- "$build_dir" && pwd -P)

if [ "${GNOSTIC_DEVCONTAINER:-0}" = "1" ]; then
    exec "$root_dir/.devcontainer/lock.sh" "$build_dir" "$build_lock_timeout" \
        timeout --signal=TERM --kill-after=5s "${container_timeout}s" "$@"
fi

if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found; install a container runtime or enter the supported development container" >&2
    exit 1
fi

exec "$root_dir/.devcontainer/lock.sh" "$build_dir" "$build_lock_timeout" \
    env BUILD_DIR="$build_dir" "$root_dir/.devcontainer/run-container.sh" "$@"
