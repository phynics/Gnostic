#!/usr/bin/env bash

set -euo pipefail

filter=${FILTER:-}
repeat_count=${N:-1}
timeout_seconds=${TEST_TIMEOUT:-3600}
if [[ -z "$filter" ]]; then
    echo "Set FILTER to a Swift test name or suite name" >&2
    exit 2
fi
if [[ ! "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "N must be a positive integer, got: $repeat_count" >&2
    exit 2
fi
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "TEST_TIMEOUT must be a positive integer, got: $timeout_seconds" >&2
    exit 2
fi
repeat_count=$((10#$repeat_count))

read -r -a swift_flags <<< "${SWIFT_FLAGS:---cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native --quiet -Xswiftc -warnings-as-errors}"
mkdir -p .testing
safe_filter=$(printf '%s' "$filter" | tr -c '[:alnum:]._+-' '_')
setup_log=".testing/focused-${safe_filter}-setup.log"
: > "$setup_log"

run_logged() {
    local log_path=$1
    local command_timeout=$2
    local status=0
    shift 2

    if timeout --signal=TERM --kill-after=5s "${command_timeout}s" "$@" 2>&1 | tee -a "$log_path"; then
        return 0
    else
        status=$?
        echo "Focused command failed with exit status $status; diagnostics: $log_path" >&2
        return "$status"
    fi
}

if ! pgrep mosquitto >/dev/null 2>&1; then
    run_logged "$setup_log" "$timeout_seconds" mosquitto -c /etc/mosquitto/gnostic.conf -d || exit $?
fi

run_logged "$setup_log" "$timeout_seconds" npm ci --prefix Tests/Fixtures/OfficialACPClient --cache .build/npm-cache || exit $?
run_logged "$setup_log" "$timeout_seconds" npm ci --legacy-peer-deps --prefix Tests/Fixtures/PiACPClient --cache .build/npm-cache || exit $?
run_logged "$setup_log" "$timeout_seconds" npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache || exit $?
run_logged "$setup_log" "$timeout_seconds" swift build "${swift_flags[@]}" --product gnostic || exit $?
run_logged "$setup_log" "$timeout_seconds" swift build "${swift_flags[@]}" --product gnostic-pk-runtime || exit $?

bin_dir_status=0
bin_dir=$(timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" swift build "${swift_flags[@]}" --show-bin-path 2>>"$setup_log") || bin_dir_status=$?
if (( bin_dir_status != 0 )); then
    echo "Could not resolve SwiftPM's executable directory; diagnostics: $setup_log" >&2
    exit "$bin_dir_status"
fi
bin="$bin_dir/gnostic"
if [[ ! -x "$bin" ]]; then
    echo "Could not locate built gnostic executable at $bin; diagnostics: $setup_log" >&2
    exit 1
fi
printf 'Using gnostic executable: %s\n' "$bin" | tee -a "$setup_log"

export GNOSTIC_ACP_AGENT_FIXTURE=/workspace/Tests/Fixtures/ACPAgent/agent.mjs
export GNOSTIC_SERVE_BINARY="$bin"
export GNOSTIC_CLI_BINARY="$bin"

export GNOSTIC_ACP_BINARY="$bin"
runtime_bin_dir=$(timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" swift build "${swift_flags[@]}" --product gnostic-pk-runtime --show-bin-path 2>>"$setup_log") || exit $?
export GNOSTIC_PK_RUNTIME_BINARY="$runtime_bin_dir/gnostic-pk-runtime"
if [[ ! -x "$GNOSTIC_PK_RUNTIME_BINARY" ]]; then
    echo "Could not locate gnostic-pk-runtime at $GNOSTIC_PK_RUNTIME_BINARY; diagnostics: $setup_log" >&2
    exit 1
fi
export GNOSTIC_ACP_OFFICIAL_CLIENT=/workspace/Tests/Fixtures/OfficialACPClient/lifecycle.mjs
export GNOSTIC_PI_ACP_CLIENT_FIXTURE=/workspace/Tests/Fixtures/PiACPClient/lifecycle.mjs

for ((iteration = 1; iteration <= repeat_count; iteration++)); do
    log_path=".testing/focused-${safe_filter}-${iteration}.log"
    : > "$log_path"
    test_command=(swift test "${swift_flags[@]}" --no-parallel --filter "$filter")
    if (( iteration > 1 )); then
        test_command+=(--skip-build)
    fi

    echo "Focused test $iteration/$repeat_count: $filter (timeout ${timeout_seconds}s)" | tee -a "$log_path"
    run_logged "$log_path" "$timeout_seconds" "${test_command[@]}" || exit $?

    if grep -Eq 'Test run with 0 tests?|No matching tests' "$log_path"; then
        echo "No tests matched FILTER=$filter; diagnostics: $log_path" >&2
        exit 1
    fi
    if ! grep -Eq 'Test run with [1-9][0-9]* tests?' "$log_path"; then
        echo "No tests matched FILTER=$filter; diagnostics: $log_path" >&2
        exit 1
    fi
done

echo "Focused test passed: $filter ($repeat_count run(s)); diagnostics: .testing/focused-${safe_filter}-*.log"
