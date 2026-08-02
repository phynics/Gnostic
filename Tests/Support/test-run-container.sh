#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
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
    if ! rg -F --quiet -- "$needle" "$file"; then
        fail "$name (missing: $needle)"
    fi
}

assert_line_once() {
    expected=$1
    file=$2
    name=$3
    if [ ! -f "$file" ]; then
        fail "$name (runtime did not record arguments)"
        return
    fi
    count=$(awk -v expected="$expected" '$0 == expected { count++ } END { print count + 0 }' "$file")
    [ "$count" = "1" ] || fail "$name (expected once, got $count)"
}

run_capture() {
    output_file=$1
    shift
    run_status=0
    "$@" >"$output_file" 2>&1 || run_status=$?
}

test_direct_command_preserves_exit_status() {
    output="$fixture_dir/direct.out"
    run_capture "$output" env \
        GNOSTIC_DEVCONTAINER=1 \
        BUILD_DIR="$fixture_dir/direct-build" \
        "$root_dir/.devcontainer/run.sh" sh -c 'exit 7'
    assert_status 7 "$run_status" "GNOSTIC_DEVCONTAINER direct command"
}

test_missing_runtime_fails() {
    output="$fixture_dir/runtime.out"
    run_capture "$output" env \
        CONTAINER_RUNTIME= \
        BUILD_DIR="$fixture_dir/runtime-build" \
        "$root_dir/.devcontainer/run.sh" true
    assert_status 1 "$run_status" "missing runtime"
    assert_contains "No podman or docker runtime found" "$output" "missing runtime diagnostic"
}

test_invalid_build_lock_fails() {
    output="$fixture_dir/build-lock.out"
    run_capture "$output" env \
        BUILD_LOCK=2 \
        CONTAINER_RUNTIME= \
        BUILD_DIR="$fixture_dir/invalid-lock-build" \
        "$root_dir/.devcontainer/run.sh" true
    assert_status 2 "$run_status" "invalid BUILD_LOCK"
    assert_contains "BUILD_LOCK must be 0 or 1" "$output" "invalid BUILD_LOCK diagnostic"
}

test_runtime_receives_each_mount_once() {
    runtime="$fixture_dir/fake-runtime"
    captured="$fixture_dir/runtime-arguments"
    build_dir="$fixture_dir/build"
    cache_dir="$fixture_dir/cache"
    extra_dir="$fixture_dir/extra"
    mkdir -p "$extra_dir"
    cat >"$runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_RUNTIME_ARGUMENTS"
EOF
    chmod +x "$runtime"

    output="$fixture_dir/mounts.out"
    run_capture "$output" env \
        CONTAINER_RUNTIME="$runtime" \
        FAKE_RUNTIME_ARGUMENTS="$captured" \
        BUILD_DIR="$build_dir" \
        SPM_CACHE_DIR="$cache_dir" \
        EXTRA_CONTAINER_MOUNTS="-v $extra_dir:/extra:ro" \
        IMAGE=fixture-image \
        "$root_dir/.devcontainer/run.sh" swift --version
    assert_status 0 "$run_status" "fake runtime invocation"

    assert_line_once "$root_dir:/workspace" "$captured" "repository bind"
    assert_line_once "$build_dir:/workspace/.build" "$captured" "build bind"
    assert_line_once "$cache_dir:/workspace/.swiftpm-cache" "$captured" "SwiftPM cache bind"
    assert_line_once "$extra_dir:/extra:ro" "$captured" "extra bind"
}

test_failing_child_releases_lock() {
    output="$fixture_dir/lock.out"
    build_dir="$fixture_dir/locked-build"
    run_capture "$output" env \
        GNOSTIC_DEVCONTAINER=1 \
        BUILD_DIR="$build_dir" \
        BUILD_LOCK=1 \
        "$root_dir/.devcontainer/run.sh" sh -c 'exit 23'
    assert_status 23 "$run_status" "failing child exit status"
    [ ! -d "$build_dir.lock" ] || fail "failing child releases build lock"
}

test_tooling_only_make_targets_fail_for_missing_manifest() {
    for target in resolve build test verify; do
        output="$fixture_dir/make-$target.out"
        run_capture "$output" make -C "$root_dir" "$target"
        assert_status 2 "$run_status" "make $target on tooling-only branch"
        assert_contains "Package.swift is not present on this branch" "$output" "make $target missing manifest diagnostic"
    done
}

test_direct_command_preserves_exit_status
test_missing_runtime_fails
test_invalid_build_lock_fails
test_runtime_receives_each_mount_once
test_failing_child_releases_lock
test_tooling_only_make_targets_fail_for_missing_manifest

if [ "$failures" -gt 0 ]; then
    echo "$failures harness test(s) failed" >&2
    exit 1
fi

echo "6 harness tests passed"
