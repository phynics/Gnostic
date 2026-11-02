#!/usr/bin/env bash
#
# macOS product proof (#694). Builds release `gnostic` and `gnostic-pk-runtime`,
# runs the Swift test suite against a local broker, and then runs the
# filesystem Workspace scenario against the release binary. The environment
# matches Scripts/run-focused-tests.sh, except that paths point into this
# checkout instead of /workspace.
#
# Requires macOS, Homebrew with `mosquitto` and `guile` installed, and Node.js.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "macOS product proof requires macOS" >&2
    exit 1
fi

command -v brew >/dev/null
command -v npm >/dev/null
prefix=$(brew --prefix)
mosquitto_bin="$prefix/sbin/mosquitto"
[[ -x "$mosquitto_bin" ]] || mosquitto_bin=$(command -v mosquitto)
command -v mosquitto_pub >/dev/null
command -v guile >/dev/null

log_dir=.testing/macos-product-proof
rm -rf "$log_dir"
mkdir -p "$log_dir"

{
    sw_vers
    xcodebuild -version
    swift --version
    node --version
    "$mosquitto_bin" -h | head -n 1
    guile --version | head -n 1
} 2>&1 | tee "$log_dir/toolchain.log"

# Tests that do not run on macOS, each with its reason. This is the complete
# record of exclusions. `run_suite` fails on any other skipped test.
#
# Compiled out with `#if !canImport(Darwin)`:
# - FilesystemWorkspaceTests.canonicallyEqualSiblingIsOutsideTheRoot: APFS treats
#   the test's two directory names as one directory.
expected_skips=(
    # RLMChibiWorkerSessionTests.fileDescriptorsAbsent reads /proc, which macOS
    # does not have.
    'the worker process holds only its standard file descriptors'
)

swift_flags=(
    --cache-path "$repo_root/.swiftpm-cache"
    --disable-automatic-resolution
    --build-system native
    -Xswiftc -warnings-as-errors
)
# Test runs keep Swift Testing's per-test output, so a hung run names the test
# it stopped in. Swift Testing buffers that output when stdout is a pipe, so
# `run_suite` gives it a pseudo-terminal. Builds stay quiet.
build_flags=("${swift_flags[@]}" --quiet)

# Upper bound for one `swift test` run. A hung macOS test would otherwise hold
# the job until its timeout and lose the logs.
suite_timeout_seconds=${SUITE_TIMEOUT:-1800}

scratch=$(mktemp -d)
mosquitto_pid=
cleanup() {
    if [[ -n "$mosquitto_pid" ]]; then
        kill "$mosquitto_pid" 2>/dev/null || true
        wait "$mosquitto_pid" 2>/dev/null || true
    fi
    if [[ -f "$scratch/mosquitto.log" ]]; then
        cp "$scratch/mosquitto.log" "$log_dir/mosquitto.log" || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

# Same listeners as the development container (.devcontainer/Dockerfile): 1883
# anonymous and 1884 password-protected with the fixture credential.
mosquitto_passwd -b -c "$scratch/gnostic.passwd" gnostic-test gnostic-secret
printf '%s\n' \
    'per_listener_settings true' \
    '' \
    'listener 1883 127.0.0.1' \
    'allow_anonymous true' \
    '' \
    'listener 1884 127.0.0.1' \
    'allow_anonymous false' \
    "password_file $scratch/gnostic.passwd" \
    '' \
    'persistence false' \
    'log_dest stderr' \
    >"$scratch/mosquitto.conf"
"$mosquitto_bin" -c "$scratch/mosquitto.conf" >"$scratch/mosquitto.log" 2>&1 &
mosquitto_pid=$!
broker_ready=0
for _ in $(seq 1 50); do
    if mosquitto_pub -h 127.0.0.1 -p 1883 -t gnostic/macos/readiness -m ready >/dev/null 2>&1; then
        broker_ready=1
        break
    fi
    kill -0 "$mosquitto_pid" 2>/dev/null || break
    sleep 0.2
done
if (( broker_ready == 0 )); then
    echo "Mosquitto did not become ready on 127.0.0.1:1883" >&2
    cat "$scratch/mosquitto.log" >&2 || true
    exit 1
fi

npm ci --prefix Tests/Fixtures/OfficialACPClient --cache .build/npm-cache
npm ci --legacy-peer-deps --prefix Tests/Fixtures/PiACPClient --cache .build/npm-cache
npm ci --prefix Tests/Fixtures/ACPAgent --cache .build/npm-cache

# The RLM suites in the full run need the Guile and Chibi executors, which the
# Linux container bakes in.
PREFIX="$prefix" bash Scripts/install-rlm-limit-exec.sh
PREFIX="$prefix" bash Scripts/build-chibi-rlm.sh
export GNOSTIC_GUILE="$(command -v guile)"
export GNOSTIC_CHIBI="$prefix/bin/chibi-scheme"

# Release products: the shipped configuration.
swift build "${build_flags[@]}" -c release --product gnostic
swift build "${build_flags[@]}" -c release --product gnostic-pk-runtime
release_bin_dir=$(swift build "${build_flags[@]}" -c release --show-bin-path)
release_gnostic="$release_bin_dir/gnostic"
release_runtime="$release_bin_dir/gnostic-pk-runtime"
for binary in "$release_gnostic" "$release_runtime"; do
    [[ -x "$binary" ]] || { echo "Missing release executable: $binary" >&2; exit 1; }
done
printf 'Release gnostic: %s\nRelease gnostic-pk-runtime: %s\n' \
    "$release_gnostic" "$release_runtime" | tee "$log_dir/release-binaries.log"

# Debug products and test bundles: the configuration `make verify` tests.
swift build "${build_flags[@]}" --product gnostic
swift build "${build_flags[@]}" --product gnostic-pk-runtime
swift build "${build_flags[@]}" --build-tests
debug_bin_dir=$(swift build "${build_flags[@]}" --show-bin-path)

export GNOSTIC_ACP_AGENT_FIXTURE="$repo_root/Tests/Fixtures/ACPAgent/agent.mjs"
export GNOSTIC_ACP_OFFICIAL_CLIENT="$repo_root/Tests/Fixtures/OfficialACPClient/lifecycle.mjs"
export GNOSTIC_PI_ACP_CLIENT_FIXTURE="$repo_root/Tests/Fixtures/PiACPClient/lifecycle.mjs"

# Prints the descendants of a process, children first.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        descendants "$child"
        echo "$child"
    done
}

# Records the stacks of a process and all its descendants next to $timeout_marker.
sample_tree() {
    local parent=$1 child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        sample_tree "$child"
    done
    sample "$parent" 2 -file "${timeout_marker%.timeout}-sample-$parent.txt" >/dev/null 2>&1 || true
}

# Runs a command, sampling and then terminating it and its descendants after $1
# seconds, and returns 124 if that happened. macOS has no timeout(1). The watchdog
# logs to $timeout_marker, not to the pipe. It signals the command's process group
# and the descendants recorded before and after sampling, because a Runtime can
# lead its own group, and a descendant that outlives its parent can no longer be
# found through the parent. It finishes escalating before this returns.
run_bounded() {
    local seconds=$1 status=0 pid watchdog child
    shift
    # Job control gives the command its own process group. Its members can still
    # be signalled after their parent dies, including any started during sampling.
    set -m
    "$@" &
    pid=$!
    set +m
    (
        exec >/dev/null 2>&1
        sleep "$seconds"
        echo "Timed out after ${seconds}s: $*" >"$timeout_marker"
        targets="$(descendants "$pid") $pid"
        sample_tree "$pid"
        targets="$targets $(descendants "$pid")"
        # shellcheck disable=SC2086
        kill -TERM -- "-$pid" $targets 2>/dev/null || true
        sleep 10
        # shellcheck disable=SC2086
        kill -KILL -- "-$pid" $targets 2>/dev/null || true
    ) &
    watchdog=$!
    wait "$pid" || status=$?
    if [[ ! -f "$timeout_marker" ]]; then
        for child in $(descendants "$watchdog") "$watchdog"; do
            kill -TERM "$child" 2>/dev/null || true
        done
    fi
    wait "$watchdog" 2>/dev/null || true
    if [[ -f "$timeout_marker" ]]; then
        return 124
    fi
    return "$status"
}

# Runs `swift test` with the given binaries, then fails unless the run executed
# the expected number of tests. $1 label, $2 gnostic, $3 gnostic-pk-runtime,
# $4 required "Test run with" pattern, remaining arguments go to `swift test`.
run_suite() {
    local label=$1 gnostic=$2 runtime=$3 expected=$4
    shift 4
    local log="$log_dir/$label.log"
    local status=0
    timeout_marker="$log_dir/$label.timeout"
    NO_COLOR=1 \
        GNOSTIC_SERVE_BINARY="$gnostic" \
        GNOSTIC_CLI_BINARY="$gnostic" \
        GNOSTIC_ACP_BINARY="$gnostic" \
        GNOSTIC_PK_RUNTIME_BINARY="$runtime" \
        run_bounded "$suite_timeout_seconds" \
        script -q /dev/null swift test "${swift_flags[@]}" --skip-build --no-parallel \
        --xunit-output "$log_dir/$label.xml" "$@" 2>&1 </dev/null | tee "$log" || status=$?
    if [[ -f "$timeout_marker" ]]; then
        cat "$timeout_marker" >&2
    fi
    if (( status != 0 )); then
        echo "$label failed with exit status $status; log: $log" >&2
        return "$status"
    fi
    if ! grep -Eq "Test run with $expected" "$log"; then
        echo "$label did not execute the expected tests; log: $log" >&2
        return 1
    fi
    local unexpected_skips
    unexpected_skips=$(grep -E '(Test|Suite) ".*" skipped' "$log" |
        grep -vF -f <(printf '%s\n' "${expected_skips[@]}") || true)
    if [[ -n "$unexpected_skips" ]]; then
        printf '%s skipped tests that are not recorded as macOS exclusions:\n%s\n' \
            "$label" "$unexpected_skips" >&2
        return 1
    fi
}

failed=0
timeout_marker=/dev/null

# Release proof: the filesystem Workspace is the only kind a release build
# registers, and its containment path uses macOS F_GETPATH.
run_suite release-filesystem-workspace "$release_gnostic" "$release_runtime" \
    '1 test' \
    --filter 'TwoNodeMQTTIntegrationTests/runtimeReadsPeerFilesystemWorkspace' || failed=1

run_suite full-suite "$debug_bin_dir/gnostic" "$debug_bin_dir/gnostic-pk-runtime" \
    '[1-9][0-9]* tests' || failed=1

exit "$failed"
