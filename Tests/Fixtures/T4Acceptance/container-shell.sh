#!/bin/sh
# Open an interactive shell in the pinned development container, or run one command in it.
#
#   Tests/Fixtures/T4Acceptance/container-shell.sh [command [argument...]]
#
# `make shell` cannot do this: the container runner starts the container in the
# background without a terminal, so the shell exits at once. This script starts the same
# image with the same mounts and the same host user, and it keeps stdin and the terminal.
# Run it from the repository root. It reads these variables:
#   CONTAINER_RUNTIME     podman or docker. Default: the first one on PATH.
#   BUILD_CONFIGURATION   release (default) or debug. Chooses the build directory.
#   CONTAINER_TIMEOUT     Seconds before the container is stopped. Default: 7200.
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
runtime=${CONTAINER_RUNTIME:-$(command -v podman 2> /dev/null || command -v docker 2> /dev/null || true)}
if [ -z "$runtime" ]; then
	echo "No podman or docker runtime found." >&2
	exit 1
fi
timeout_seconds=${CONTAINER_TIMEOUT:-7200}

cd "$root_dir"
make image CONTAINER_RUNTIME="$runtime" > /dev/null
image=gnostic-dev:$(./.devcontainer/image-fingerprint.sh .)
export BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
build_dir=$(./Scripts/gnostic-build-path.sh build-dir)
swift_version=$(./Scripts/gnostic-build-path.sh swift-version)
spm_cache_dir=${SPM_CACHE_DIR:-$HOME/.cache/gnostic/swiftpm/swift-$swift_version-linux}
mkdir -p "$build_dir" "$spm_cache_dir"

# Rootless podman maps the host user to container root. `--userns=keep-id` keeps
# the host user ID inside the container, so the bind mounts stay writable.
case $(basename -- "$runtime") in
	podman) userns=--userns=keep-id ;;
	*) userns= ;;
esac
if [ -t 0 ]; then terminal=-it; else terminal=-i; fi
[ "$#" -gt 0 ] || set -- bash

exec timeout --foreground --signal=TERM --kill-after=5s "${timeout_seconds}s" \
	"$runtime" run --rm $terminal $userns --user "$(id -u):$(id -g)" \
	-e HOME=/tmp -e BUILD_CONFIGURATION \
	-v "$root_dir:/workspace" -v "$build_dir:/workspace/.build" \
	-v "$spm_cache_dir:/workspace/.swiftpm-cache" -w /workspace \
	"$image" "$@"
