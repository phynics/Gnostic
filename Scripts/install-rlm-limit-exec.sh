#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prefix=${PREFIX:-/usr/local}
destination="${DESTDIR:-}${prefix}/bin"
temporary_binary=$(mktemp)
trap 'rm -f "$temporary_binary"' EXIT INT TERM

"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
    "$script_dir/gnostic-rlm-limit-exec.c" -o "$temporary_binary"
mkdir -p "$destination"
install -m 0755 "$temporary_binary" "$destination/gnostic-rlm-limit-exec"
