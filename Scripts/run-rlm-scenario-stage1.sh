#!/usr/bin/env bash

# Stage 1 of the #354 scenario manifest: the macOS environment rows M13 and
# M14. No provider credentials and no spend. Writes
# Documentation/Experiments/rlm-scenario-stage1.json.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Stage 1 scenario rows require macOS" >&2
    exit 1
fi

stage_dir=.testing/rlm-scenario-stage1
rm -rf "$stage_dir"
mkdir -p "$stage_dir" Documentation/Experiments

# The smoke builds the launcher and patched Chibi, then runs every session,
# denial, signal, operation, and parity suite with per-test xUnit reports.
bash Scripts/macos-rlm-smoke.sh 2>&1 | tee "$stage_dir/smoke.log"

prefix=$(brew --prefix)
launcher="$prefix/bin/gnostic-rlm-limit-exec"
probes="$stage_dir/probes.jsonl"
: > "$probes"

record_probe() {
    printf '{"probe":"%s","status":"%s","exitStatus":%s,"detail":"%s"}\n' "$1" "$2" "$3" "$4" >> "$probes"
}

# CPU: the launcher applies RLIMIT_CPU and the child observes it before exec.
status=0
"$launcher" --cpu=10 -- /bin/sh -c 'test "$(ulimit -t)" -eq 10' || status=$?
if [[ $status -eq 0 ]]; then
    record_probe cpu-limit-applied passed "$status" "child observes ulimit -t 10"
else
    record_probe cpu-limit-applied failed "$status" "child did not observe ulimit -t 10"
fi

# CPU: the kernel terminates a CPU-bound child at the limit (SIGXCPU = 24).
started=$(date +%s)
status=0
"$launcher" --cpu=1 -- /bin/sh -c 'while :; do :; done' &
spinner=$!
( sleep 20; kill -KILL "$spinner" 2>/dev/null ) &
watchdog=$!
wait "$spinner" || status=$?
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
elapsed=$(( $(date +%s) - started ))
if [[ $status -eq $((128 + 24)) && $elapsed -lt 20 ]]; then
    record_probe cpu-limit-enforced passed "$status" "SIGXCPU after ${elapsed}s wall"
else
    record_probe cpu-limit-enforced failed "$status" "expected SIGXCPU before the 20s watchdog; took ${elapsed}s"
fi

# Address space: Darwin has no enforceable RLIMIT_AS, so the launcher must
# refuse the request instead of silently starting an unbounded worker.
status=0
stderr_output=$("$launcher" --cpu=10 --as=268435456 -- /usr/bin/true 2>&1) || status=$?
if [[ $status -ne 0 ]] && grep -Fq "address-space limit is unsupported" <<<"$stderr_output"; then
    record_probe address-space-request-rejected passed "$status" "launcher refuses --as on Darwin"
else
    record_probe address-space-request-rejected failed "$status" "launcher accepted or misreported --as on Darwin"
fi

guile_path=$(command -v guile)
GNOSTIC_STAGE1_COMMIT=$(git rev-parse HEAD) \
GNOSTIC_STAGE1_GUILE="$guile_path" \
GNOSTIC_STAGE1_GUILE_VERSION="$(guile --version | head -n 1)" \
GNOSTIC_STAGE1_GUILE_FORMULA="$(brew list --versions guile)" \
GNOSTIC_STAGE1_CHIBI="$prefix/bin/chibi-scheme" \
GNOSTIC_STAGE1_LAUNCHER="$launcher" \
GNOSTIC_STAGE1_OS_VERSION="$(sw_vers -productVersion)" \
GNOSTIC_STAGE1_ARCH="$(uname -m)" \
GNOSTIC_STAGE1_SWIFT="$(swift --version 2>&1 | grep -m 1 -o 'Apple Swift version [0-9.]*')" \
    node Scripts/assemble-rlm-scenario-stage1.mjs \
        --evidence .testing/macos-rlm-smoke \
        --probes "$probes" \
        --output Documentation/Experiments/rlm-scenario-stage1.json

printf 'Wrote %s\n' Documentation/Experiments/rlm-scenario-stage1.json
