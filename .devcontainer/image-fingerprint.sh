#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 CONTEXT" >&2
    exit 2
fi

context=$(CDPATH= cd -- "$1" && pwd -P)
fingerprint_inputs='
.devcontainer/Dockerfile
.dockerignore
.devcontainer/patches/chibi-cell-timeout.patch
Scripts/build-chibi-rlm.sh
Scripts/gnostic-rlm-limit-exec.c
Scripts/install-rlm-limit-exec.sh
'

fingerprint_material=
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "$context/$path" ]; then
        echo "Missing development image input: $context/$path" >&2
        exit 2
    fi
    if command -v shasum >/dev/null 2>&1; then
        input_hash=$(shasum -a 256 "$context/$path" | awk '{ print $1 }')
    elif command -v sha256sum >/dev/null 2>&1; then
        input_hash=$(sha256sum "$context/$path" | awk '{ print $1 }')
    else
        echo "A SHA-256 utility (shasum or sha256sum) is required" >&2
        exit 2
    fi
    fingerprint_material="${fingerprint_material}${path} ${input_hash}
"
done <<EOF
$fingerprint_inputs
EOF

if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$fingerprint_material" | shasum -a 256 | awk '{ print $1 }'
else
    printf '%s' "$fingerprint_material" | sha256sum | awk '{ print $1 }'
fi
