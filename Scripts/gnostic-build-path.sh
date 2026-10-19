#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
worktree_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo_root")
worktree_root=$(CDPATH= cd -- "$worktree_root" && pwd -P)
common_dir=$(git -C "$worktree_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$worktree_root")
common_dir=$(CDPATH= cd -- "$common_dir" && pwd -P)
default_swift_version=$(awk '$1 == "FROM" && $2 ~ /^swift:[0-9]/ { sub(/^swift:/, "", $2); sub(/-.*/, "", $2); print $2; exit }' "$repo_root/.devcontainer/Dockerfile")
if [ -z "$default_swift_version" ]; then
    echo "Could not determine Swift toolchain version from .devcontainer/Dockerfile" >&2
    exit 2
fi

sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{ print $1 }'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{ print $1 }'
    else
        echo "A SHA-256 utility (shasum or sha256sum) is required" >&2
        exit 2
    fi
}

hash_path() {
    printf '%s' "$1" | sha256
}

case $(uname -m) in
    x86_64|amd64) default_platform=linux-amd64 ;;
    aarch64|arm64) default_platform=linux-arm64 ;;
    *) default_platform=linux-$(uname -m) ;;
esac

repository_name=$(basename "${common_dir%/.git}")
repository_hash=$(hash_path "$common_dir" | cut -c 1-12)
worktree_hash=$(hash_path "$worktree_root")
repository_id="${repository_name}-${repository_hash}"
configuration=${BUILD_CONFIGURATION:-debug}
toolchain_version=${SWIFT_TOOLCHAIN_VERSION:-$default_swift_version}
cache_namespace=${CACHE_NAMESPACE:-swift-$toolchain_version-linux}
build_system=${SWIFT_BUILD_SYSTEM:-native}
platform=${BUILD_TARGET_PLATFORM:-$default_platform}
cache_root=${BUILD_CACHE_ROOT:-/tmp/gnostic-swift-build/$repository_id/$cache_namespace-$build_system-$platform/worktrees/$worktree_hash}

case ${1:-build-dir} in
    swift-version) printf '%s\n' "$toolchain_version" ;;
    repository-id) printf '%s\n' "$repository_id" ;;
    worktree-id) printf '%s\n' "$worktree_hash" ;;
    platform) printf '%s\n' "$platform" ;;
    build-root) printf '%s\n' "$cache_root" ;;
    build-dir) printf '%s\n' "${BUILD_DIR:-$cache_root/$configuration}" ;;
    *) echo "usage: $0 [repository-id|worktree-id|platform|build-root|build-dir]" >&2; exit 2 ;;
esac
