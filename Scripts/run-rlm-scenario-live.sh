#!/usr/bin/env bash

# Runs `gnostic experiment rlm-scenario` inside the pinned dev image, so every
# live run records the image ID it executed against (#354 manifest §7).
#
#   make scenario-live CONFIG=~/.config/gnostic/manifest.json \
#       ARGS="--stage pilot --ascendant <uuid> --input-price 3 --output-price 15 --prices-date 2026-09-25"
#
# Without --confirm-spend in ARGS the command only prints the plan.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ -z "${CONFIG:-}" || ! -f "${CONFIG}" ]]; then
    echo "CONFIG=<path to the node manifest holding the Ascendant's provider and key> is required" >&2
    exit 2
fi
if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

commit=$(git rev-parse HEAD)
image_digest=$("$CONTAINER_RUNTIME" image inspect "${IMAGE:-gnostic-dev}" --format '{{.Id}}')

# The manifest carries a provider key: copy it to a private directory for the
# run instead of placing it under the mounted repository.
config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT INT TERM
chmod 700 "$config_dir"
install -m 600 "$CONFIG" "$config_dir/manifest.json"

export EXTRA_CONTAINER_MOUNTS="${EXTRA_CONTAINER_MOUNTS:-} -v $config_dir:/run/gnostic"
./.devcontainer/run.sh bash -o pipefail -c "
    export GNOSTIC_SCENARIO_COMMIT='$commit' GNOSTIC_SCENARIO_IMAGE_DIGEST='$image_digest'
    bin=\$(swift build ${SWIFT_LOCKED_ARGS:-} --show-bin-path)/gnostic
    test -x \"\$bin\" || { echo \"Could not locate built gnostic executable at \$bin\" >&2; exit 1; }
    \"\$bin\" experiment rlm-scenario --config /run/gnostic/manifest.json ${ARGS:-}
"
