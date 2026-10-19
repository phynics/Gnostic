#!/bin/sh

set -eu

if [ "${GNOSTIC_DEVCONTAINER:-0}" = 1 ]; then
    echo "Using the current Gnostic development container"
    exit 0
fi

if [ "$#" -ne 3 ]; then
    echo "usage: $0 CONTAINER_RUNTIME IMAGE CONTEXT" >&2
    exit 2
fi

runtime=$1
image=$2
context=$(CDPATH= cd -- "$3" && pwd -P)
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

fingerprint=$("$script_dir/image-fingerprint.sh" "$context")

label=io.gnostic.devcontainer.fingerprint
installed_fingerprint=$(
    "$runtime" image inspect --format "{{ index .Config.Labels \"$label\" }}" "$image" 2>/dev/null || true
)

if [ "$installed_fingerprint" = "$fingerprint" ]; then
    echo "Reusing unchanged development image $image ($fingerprint)"
    exit 0
fi

echo "Building development image $image (input fingerprint $fingerprint)"
"$runtime" build --label "$label=$fingerprint" -t "$image" -f "$context/.devcontainer/Dockerfile" "$context"
