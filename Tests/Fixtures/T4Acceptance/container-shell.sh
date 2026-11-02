#!/bin/sh
# Open an interactive shell in the pinned development container, or run one command in it.
#
#   Tests/Fixtures/T4Acceptance/container-shell.sh                      An interactive shell.
#   Tests/Fixtures/T4Acceptance/container-shell.sh command [argument...] One command, then exit.
#
# `make shell` cannot do this: `.devcontainer/lock.sh` and `.devcontainer/run-container.sh`
# run the container in a background job, which has no stdin and no terminal, so the shell
# exits at once. This script starts the same image with the same mounts and the same host
# user, and it keeps stdin and the terminal. Run it from anywhere in the repository.
#
# Locking follows the Make targets for a command that can write the build directory:
#   - With a command, the script holds the build directory lock (BUILD_LOCK_TIMEOUT seconds
#     to get it, 1800 by default) before it starts the container, as `.devcontainer/run.sh`
#     does. A concurrent `make clean` or `make build` for the same worktree and
#     configuration waits for the command, and the command waits for them.
#   - Without a command, the shell holds no lock and mounts the build directory read-only.
#     A shell stays open for hours, and the drills only run the built binaries, so a lock
#     would block every Make target in the worktree for as long. The price: do not run
#     `make clean` or a build for this worktree while the shell is open.
#
# Variables:
#   CONTAINER_RUNTIME     podman or docker. Default: the first one on PATH.
#   BUILD_CONFIGURATION   release (default) or debug. Chooses the build directory.
#   CONTAINER_TIMEOUT     Seconds before the container is stopped. Default: 7200.
#   BUILD_LOCK_TIMEOUT    Seconds to wait for the build directory lock. Default: 1800.
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
cd "$root_dir"
export BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
build_dir=$(./Scripts/gnostic-build-path.sh build-dir)
mkdir -p "$build_dir"
build_dir=$(CDPATH= cd -- "$build_dir" && pwd -P)

# A command takes the lock first, and everything else runs under it.
if [ "$#" -gt 0 ] && [ -z "${T4_CONTAINER_LOCKED:-}" ]; then
	T4_CONTAINER_LOCKED=1 exec ./.devcontainer/lock.sh "$build_dir" "${BUILD_LOCK_TIMEOUT:-1800}" \
		"$root_dir/Tests/Fixtures/T4Acceptance/container-shell.sh" "$@"
fi

runtime=${CONTAINER_RUNTIME:-$(command -v podman 2> /dev/null || command -v docker 2> /dev/null || true)}
if [ -z "$runtime" ]; then
	echo "No podman or docker runtime found." >&2
	exit 1
fi
timeout_seconds=${CONTAINER_TIMEOUT:-7200}

make image CONTAINER_RUNTIME="$runtime" > /dev/null
image=gnostic-dev:$(./.devcontainer/image-fingerprint.sh .)
swift_version=$(./Scripts/gnostic-build-path.sh swift-version)
spm_cache_dir=${SPM_CACHE_DIR:-$HOME/.cache/gnostic/swiftpm/swift-$swift_version-linux}
mkdir -p "$spm_cache_dir"

# Rootless podman maps the host user to container root. `--userns=keep-id` keeps
# the host user ID inside the container, so the bind mounts stay writable.
case $(basename -- "$runtime") in
	podman) userns=--userns=keep-id ;;
	*) userns= ;;
esac
if [ -t 0 ]; then terminal=-it; else terminal=-i; fi
# Only a command, which holds the lock, may write the build directory.
if [ "$#" -gt 0 ]; then build_mount="$build_dir:/workspace/.build"; else build_mount="$build_dir:/workspace/.build:ro"; fi
[ "$#" -gt 0 ] || set -- bash

exec timeout --foreground --signal=TERM --kill-after=5s "${timeout_seconds}s" \
	"$runtime" run --rm $terminal $userns --user "$(id -u):$(id -g)" \
	-e HOME=/tmp -e BUILD_CONFIGURATION \
	-v "$root_dir:/workspace" -v "$build_mount" \
	-v "$spm_cache_dir:/workspace/.swiftpm-cache" -w /workspace \
	"$image" "$@"
