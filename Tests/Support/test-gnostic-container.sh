#!/bin/sh

# Fake-runtime harness for Scripts/gnostic-container.sh. It needs no container
# runtime, no image, and no built binary, so it runs in seconds on the host or
# inside the development container.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wrapper="$root_dir/Scripts/gnostic-container.sh"
fixture_dir=$(mktemp -d)

cleanup() {
    rm -rf "$fixture_dir"
}
trap cleanup EXIT INT TERM

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

run_capture() {
    output_file=$1
    shift
    run_status=0
    "$@" >"$output_file" 2>&1 || run_status=$?
}

assert_status() {
    expected=$1
    actual=$2
    name=$3
    [ "$actual" = "$expected" ] || fail "$name (expected status $expected, got $actual)"
}

assert_contains() {
    needle=$1
    file=$2
    name=$3
    if [ ! -f "$file" ]; then
        fail "$name (missing output file)"
        return
    fi
    grep -F --quiet -- "$needle" "$file" || fail "$name (missing: $needle)"
}

assert_env_flag() {
    name=$1
    file=$2
    label=$3
    if [ ! -f "$file" ]; then
        fail "$label (runtime did not record arguments)"
        return
    fi
    count=$(awk -v name="$name" '
        previous == "-e" && $0 == name { count++ }
        { previous = $0 }
        END { print count + 0 }
    ' "$file")
    [ "$count" = "1" ] || fail "$label (expected one -e $name, got $count)"
}

assert_no_env_flag() {
    name=$1
    file=$2
    label=$3
    if [ ! -f "$file" ]; then
        fail "$label (runtime did not record arguments)"
        return
    fi
    count=$(awk -v name="$name" '
        previous == "-e" && $0 == name { count++ }
        { previous = $0 }
        END { print count + 0 }
    ' "$file")
    [ "$count" = "0" ] || fail "$label (unexpected -e $name)"
}

make_fake_runtime() {
    runtime=$1
    cat >"$runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_RUNTIME_ARGUMENTS"
{
    printf 'GNOSTIC_CONFIG=%s\n' "${GNOSTIC_CONFIG-}"
    printf 'GNOSTIC_HOST=%s\n' "${GNOSTIC_HOST-}"
    printf 'GNOSTIC_STATE_HOME=%s\n' "${GNOSTIC_STATE_HOME-}"
} >"$FAKE_RUNTIME_ENVIRONMENT"
exit 0
EOF
    chmod +x "$runtime"
}

make_build() {
    build_dir=$1
    revision=$2
    mkdir -p "$build_dir/x86_64-unknown-linux-gnu/debug"
    printf '#!/bin/sh\nexit 0\n' >"$build_dir/x86_64-unknown-linux-gnu/debug/gnostic"
    chmod +x "$build_dir/x86_64-unknown-linux-gnu/debug/gnostic"
    printf '%s\n' "$revision" >"$build_dir/gnostic-build-revision"
}

head_revision=$(git -C "$root_dir" rev-parse HEAD 2>/dev/null || true)

home="$fixture_dir/home"
mkdir -p "$home/.gnostic" "$home/.local/state/gnostic"
: >"$home/.gnostic/config.json"

test_wrapper_forwards_environment() {
    runtime="$fixture_dir/runtime-forwards"
    arguments="$fixture_dir/forwards-arguments"
    environment="$fixture_dir/forwards-environment"
    build_dir="$fixture_dir/forwards-build"
    output="$fixture_dir/forwards.out"
    make_fake_runtime "$runtime"
    make_build "$build_dir" "$head_revision"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        GNOSTIC_HOST=127.0.0.9 \
        GNOSTIC_PORT=1999 \
        GNOSTIC_NAMESPACE=fixture-ns \
        GNOSTIC_CONFIG="$home/.gnostic/config.json" \
        GNOSTIC_STATE_HOME="$home/.local/state/gnostic" \
        GNOSTIC_LLM_MODEL=fixture-model \
        GNOSTIC_MQTT_HOST= \
        "$wrapper" acp profiles --json
    assert_status 0 "$run_status" "wrapper environment invocation"

    for name in GNOSTIC_HOST GNOSTIC_PORT GNOSTIC_NAMESPACE GNOSTIC_CONFIG GNOSTIC_STATE_HOME GNOSTIC_LLM_MODEL; do
        assert_env_flag "$name" "$arguments" "forward $name"
    done
    assert_no_env_flag GNOSTIC_MQTT_HOST "$arguments" "skip empty GNOSTIC_MQTT_HOST"
    assert_contains "GNOSTIC_HOST=127.0.0.9" "$environment" "GNOSTIC_HOST reaches the runtime"
    assert_contains "GNOSTIC_CONFIG=/root/.gnostic/config.json" "$environment" "GNOSTIC_CONFIG host path is remapped"
    assert_contains "GNOSTIC_STATE_HOME=/root/.local/state/gnostic" "$environment" "GNOSTIC_STATE_HOME host path is remapped"
}

test_wrapper_rejects_config_outside_mounts() {
    runtime="$fixture_dir/runtime-config"
    arguments="$fixture_dir/config-arguments"
    environment="$fixture_dir/config-environment"
    build_dir="$fixture_dir/config-build"
    output="$fixture_dir/config.out"
    make_fake_runtime "$runtime"
    make_build "$build_dir" "$head_revision"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        GNOSTIC_CONFIG="$fixture_dir/outside/config.json" \
        "$wrapper" config show
    assert_status 2 "$run_status" "outside GNOSTIC_CONFIG is rejected"
    assert_contains "GNOSTIC_CONFIG" "$output" "outside GNOSTIC_CONFIG diagnostic names the variable"
    assert_contains "outside" "$output" "outside GNOSTIC_CONFIG diagnostic explains the path"
    [ ! -f "$arguments" ] || fail "outside GNOSTIC_CONFIG does not start the container"
}

test_wrapper_rejects_state_home_outside_mounts() {
    runtime="$fixture_dir/runtime-state"
    arguments="$fixture_dir/state-arguments"
    environment="$fixture_dir/state-environment"
    build_dir="$fixture_dir/state-build"
    output="$fixture_dir/state.out"
    make_fake_runtime "$runtime"
    make_build "$build_dir" "$head_revision"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        GNOSTIC_STATE_HOME="$fixture_dir/outside/state" \
        "$wrapper" acp
    assert_status 2 "$run_status" "outside GNOSTIC_STATE_HOME is rejected"
    assert_contains "GNOSTIC_STATE_HOME" "$output" "outside GNOSTIC_STATE_HOME diagnostic names the variable"
    [ ! -f "$arguments" ] || fail "outside GNOSTIC_STATE_HOME does not start the container"
}

test_wrapper_reports_build_identity() {
    runtime="$fixture_dir/runtime-info"
    arguments="$fixture_dir/info-arguments"
    environment="$fixture_dir/info-environment"
    build_dir="$fixture_dir/info-build"
    output="$fixture_dir/info.out"
    make_fake_runtime "$runtime"
    make_build "$build_dir" "$head_revision"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        "$wrapper" --wrapper-info
    assert_status 0 "$run_status" "wrapper info invocation"
    assert_contains "build-root $build_dir" "$output" "wrapper info reports the build root"
    assert_contains "build-revision $head_revision" "$output" "wrapper info reports the build revision"
    [ ! -f "$arguments" ] || fail "wrapper info does not start the container"
}

test_wrapper_warns_when_build_revision_differs() {
    runtime="$fixture_dir/runtime-warn"
    arguments="$fixture_dir/warn-arguments"
    environment="$fixture_dir/warn-environment"
    build_dir="$fixture_dir/warn-build"
    output="$fixture_dir/warn.out"
    make_fake_runtime "$runtime"
    make_build "$build_dir" "0000000000000000000000000000000000000000"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        "$wrapper" --help
    assert_status 0 "$run_status" "stale build still runs"
    assert_contains "warning:" "$output" "stale build warning"
}

test_wrapper_requires_a_build() {
    runtime="$fixture_dir/runtime-missing"
    arguments="$fixture_dir/missing-arguments"
    environment="$fixture_dir/missing-environment"
    build_dir="$fixture_dir/missing-build"
    output="$fixture_dir/missing.out"
    make_fake_runtime "$runtime"
    mkdir -p "$build_dir"

    run_capture "$output" env \
        HOME="$home" \
        CONTAINER_RUNTIME="$runtime" \
        GNOSTIC_BUILD_ROOT="$build_dir" \
        FAKE_RUNTIME_ARGUMENTS="$arguments" \
        FAKE_RUNTIME_ENVIRONMENT="$environment" \
        "$wrapper" --help
    assert_status 2 "$run_status" "missing build fails"
    assert_contains "is not built" "$output" "missing build diagnostic"
    [ ! -f "$arguments" ] || fail "missing build does not start the container"
}

test_wrapper_forwards_environment
test_wrapper_rejects_config_outside_mounts
test_wrapper_rejects_state_home_outside_mounts
test_wrapper_reports_build_identity
test_wrapper_warns_when_build_revision_differs
test_wrapper_requires_a_build

if [ "$failures" -gt 0 ]; then
    echo "$failures wrapper harness test(s) failed" >&2
    exit 1
fi

echo "6 wrapper harness tests passed"
