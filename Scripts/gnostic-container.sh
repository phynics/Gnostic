#!/bin/sh

set -eu

script_path=$(readlink -f "$0")
repo_root=$(CDPATH= cd -- "$(dirname "$script_path")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-podman}
image=${GNOSTIC_IMAGE:-}
build_root=${GNOSTIC_BUILD_ROOT:-$("$repo_root/Scripts/gnostic-build-path.sh" build-dir)}
binary=
if [ -r "$build_root/gnostic-bin-path" ]; then
    container_binary=
    IFS= read -r container_binary < "$build_root/gnostic-bin-path" || true
    case $container_binary in
        /workspace/.build/*)
            binary_relative=${container_binary#/workspace/.build/}
            case $binary_relative in
                ''|..|../*|*/..|*/../*) ;;
                *) if [ -x "$build_root/$binary_relative" ]; then binary=$container_binary; fi ;;
            esac
            ;;
    esac
fi

# Every variable the CLI reads and that a host tool may want to set. The
# wrapper forwards each one that is set and non-empty.
environment_variables="GNOSTIC_CONFIG
GNOSTIC_HOST
GNOSTIC_PORT
GNOSTIC_NAMESPACE
GNOSTIC_STATE_HOME
GNOSTIC_MQTT_HOST
GNOSTIC_MQTT_PORT
GNOSTIC_MQTT_NAMESPACE
GNOSTIC_MQTT_USERNAME
GNOSTIC_MQTT_PASSWORD
GNOSTIC_LLM_PROVIDER
GNOSTIC_LLM_ENDPOINT
GNOSTIC_LLM_MODEL
GNOSTIC_LLM_UTILITY_MODEL
GNOSTIC_LLM_FAST_MODEL
GNOSTIC_LLM_API_KEY"

# Maps a host path under host_root onto container_root, or fails. Parent
# segments are rejected so a path cannot lexically escape the mounted root.
map_path() {
    path=$1
    host_root=$2
    container_root=$3
    case $path in
        ..|../*|*/..|*/../*) return 1 ;;
    esac
    case $path in
        "$host_root") printf '%s' "$container_root" ;;
        "$host_root"/*) printf '%s/%s' "$container_root" "${path#"$host_root"/}" ;;
        *) return 1 ;;
    esac
}

build_revision() {
    if [ -f "$build_root/gnostic-build-revision" ]; then
        head -n 1 "$build_root/gnostic-build-revision" 2>/dev/null || true
    fi
}

checkout_revision() {
    git -C "$repo_root" rev-parse HEAD 2>/dev/null || true
}

case ${1:-} in
    --wrapper-info)
        printf 'wrapper %s\n' "$script_path"
        printf 'repository %s\n' "$repo_root"
        printf 'build-root %s\n' "$build_root"
        printf 'binary %s\n' "$binary"
        printf 'build-revision %s\n' "$(build_revision)"
        printf 'checkout-revision %s\n' "$(checkout_revision)"
        exit 0
        ;;
esac

if [ -z "$image" ]; then
    image="gnostic-dev:$("$repo_root/.devcontainer/image-fingerprint.sh" "$repo_root")"
fi

test -n "$binary" || {
    echo "Gnostic is not built in $build_root (build metadata is missing or invalid); run 'make build' in $repo_root" >&2
    exit 2
}

build_sha=$(build_revision)
checkout_sha=$(checkout_revision)
if [ -n "$build_sha" ] && [ -n "$checkout_sha" ] && [ "$build_sha" != "$checkout_sha" ]; then
    echo "warning: gnostic container build is $build_sha but $repo_root is at $checkout_sha; run 'make build' in $repo_root" >&2
fi

# The CLI defaults to /root/.gnostic and /root/.local/state/gnostic inside the
# container. Create and mount both host directories even when they do not exist
# yet, so a first `config init` through the wrapper is not lost on --rm exit.
mkdir -p "$HOME/.gnostic" "$HOME/.local/state/gnostic"

environment_args=""
for name in $environment_variables; do
    eval "value=\${$name-}"
    [ -n "$value" ] || continue
    case $name in
        GNOSTIC_CONFIG)
            mapped=$(map_path "$value" "$HOME/.gnostic" /root/.gnostic) || {
                echo "GNOSTIC_CONFIG=$value is outside $HOME/.gnostic; place it there so the container can read it" >&2
                exit 2
            }
            export GNOSTIC_CONFIG="$mapped"
            ;;
        GNOSTIC_STATE_HOME)
            mapped=$(map_path "$value" "$HOME/.local/state/gnostic" /root/.local/state/gnostic) || {
                echo "GNOSTIC_STATE_HOME=$value is outside $HOME/.local/state/gnostic; place it there so the container can write it" >&2
                exit 2
            }
            export GNOSTIC_STATE_HOME="$mapped"
            ;;
    esac
    environment_args="$environment_args -e $name"
done

exec "$runtime" run --rm -i --network host \
    -v "$repo_root:/workspace:ro" \
    -v "$build_root:/workspace/.build:ro" \
    -v "$HOME/.gnostic:/root/.gnostic" \
    -v "$HOME/.local/state/gnostic:/root/.local/state/gnostic" \
    $environment_args \
    -w /workspace "$image" \
    "$binary" "$@"
