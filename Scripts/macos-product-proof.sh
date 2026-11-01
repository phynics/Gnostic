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

# Tests that cannot run on macOS, each with its reason. Every entry becomes a
# `--skip` filter, so the list below is the complete record of exclusions.
excluded_tests=(
)

swift_flags=(
    --cache-path "$repo_root/.swiftpm-cache"
    --disable-automatic-resolution
    --build-system native
    --quiet
    -Xswiftc -warnings-as-errors
)

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
swift build "${swift_flags[@]}" -c release --product gnostic
swift build "${swift_flags[@]}" -c release --product gnostic-pk-runtime
release_bin_dir=$(swift build "${swift_flags[@]}" -c release --show-bin-path)
release_gnostic="$release_bin_dir/gnostic"
release_runtime="$release_bin_dir/gnostic-pk-runtime"
for binary in "$release_gnostic" "$release_runtime"; do
    [[ -x "$binary" ]] || { echo "Missing release executable: $binary" >&2; exit 1; }
done
printf 'Release gnostic: %s\nRelease gnostic-pk-runtime: %s\n' \
    "$release_gnostic" "$release_runtime" | tee "$log_dir/release-binaries.log"

# Debug products and test bundles: the configuration `make verify` tests.
swift build "${swift_flags[@]}" --product gnostic
swift build "${swift_flags[@]}" --product gnostic-pk-runtime
swift build "${swift_flags[@]}" --build-tests
debug_bin_dir=$(swift build "${swift_flags[@]}" --show-bin-path)

export GNOSTIC_ACP_AGENT_FIXTURE="$repo_root/Tests/Fixtures/ACPAgent/agent.mjs"
export GNOSTIC_ACP_OFFICIAL_CLIENT="$repo_root/Tests/Fixtures/OfficialACPClient/lifecycle.mjs"
export GNOSTIC_PI_ACP_CLIENT_FIXTURE="$repo_root/Tests/Fixtures/PiACPClient/lifecycle.mjs"

# Runs `swift test` with the given binaries, then fails unless the run executed
# the expected number of tests. $1 label, $2 gnostic, $3 gnostic-pk-runtime,
# $4 required "Test run with" pattern, remaining arguments go to `swift test`.
run_suite() {
    local label=$1 gnostic=$2 runtime=$3 expected=$4
    shift 4
    local log="$log_dir/$label.log"
    local status=0
    GNOSTIC_SERVE_BINARY="$gnostic" \
        GNOSTIC_CLI_BINARY="$gnostic" \
        GNOSTIC_ACP_BINARY="$gnostic" \
        GNOSTIC_PK_RUNTIME_BINARY="$runtime" \
        swift test "${swift_flags[@]}" --skip-build --no-parallel \
        --xunit-output "$log_dir/$label-swift-testing.xml" "$@" 2>&1 | tee "$log" || status=$?
    if (( status != 0 )); then
        echo "$label failed with exit status $status; log: $log" >&2
        return "$status"
    fi
    if ! grep -Eq "Test run with $expected" "$log"; then
        echo "$label did not execute the expected tests; log: $log" >&2
        return 1
    fi
}

failed=0

# Release proof: the filesystem Workspace is the only kind a release build
# registers, and its containment path uses macOS F_GETPATH.
run_suite release-filesystem-workspace "$release_gnostic" "$release_runtime" \
    '1 test' \
    --filter 'TwoNodeMQTTIntegrationTests/runtimeReadsPeerFilesystemWorkspace' || failed=1

skip_args=()
for excluded in ${excluded_tests[@]+"${excluded_tests[@]}"}; do
    skip_args+=(--skip "$excluded")
done
run_suite full-suite "$debug_bin_dir/gnostic" "$debug_bin_dir/gnostic-pk-runtime" \
    '[1-9][0-9]* tests' \
    ${skip_args[@]+"${skip_args[@]}"} || failed=1

exit "$failed"
