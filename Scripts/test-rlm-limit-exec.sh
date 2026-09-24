#!/usr/bin/env bash

set -euo pipefail

launcher=${1:-/usr/local/bin/gnostic-rlm-limit-exec}
test -x "$launcher"

if [[ "$(uname -s)" != Linux ]]; then
    echo "rlm limit launcher smoke requires Linux rlimits" >&2
    exit 1
fi

"$launcher" --cpu=10 --as=268435456 -- /bin/sh -c '
    test "$(ulimit -t)" -eq 10
    test "$(ulimit -v)" -eq 262144
'

marker=$(mktemp)
rm -f "$marker"
if "$launcher" --cpu=30 --as=1 -- /bin/sh -c 'touch "$1"' sh "$marker"; then
    echo "launcher executed a program without enforcing its requested memory bound" >&2
    exit 1
fi
test ! -e "$marker"
rm -f "$marker"

echo "RLM process limit launcher smoke passed"
