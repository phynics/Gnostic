#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "macOS RLM smoke requires macOS" >&2
    exit 1
fi

command -v brew >/dev/null
command -v guile >/dev/null
guile --version | grep -F "GNU Guile) 3.0."

prefix=$(brew --prefix)
PREFIX="$prefix" bash Scripts/install-rlm-limit-exec.sh
PREFIX="$prefix" bash Scripts/build-chibi-rlm.sh

launcher="$prefix/bin/gnostic-rlm-limit-exec"
"$launcher" --cpu=10 -- /bin/sh -c 'test "$(ulimit -t)" -eq 10'
if "$launcher" --cpu=10 --as=268435456 -- /usr/bin/true; then
    echo "Darwin launcher must reject unsupported address-space limits" >&2
    exit 1
fi

mkdir -p .testing
GNOSTIC_GUILE="$(command -v guile)" \
GNOSTIC_CHIBI="$prefix/bin/chibi-scheme" \
swift test --disable-automatic-resolution --build-system native \
    --quiet -Xswiftc -warnings-as-errors \
    --filter 'RLM(Guile|Chibi)(WorkerSession|SandboxDenial|ProcessSignals|Operation)Tests|RLMWorkerWireParityTests' \
    | tee .testing/macos-rlm-smoke.log
grep -Eq 'Test run with [1-9][0-9]* tests' .testing/macos-rlm-smoke.log
