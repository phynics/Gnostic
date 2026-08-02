#!/bin/sh
set -eu
test -f /workspace/Package.swift || {
    echo "Package.swift is not present on this branch" >&2
    exit 2
}
swift package resolve --cache-path /workspace/.swiftpm-cache
