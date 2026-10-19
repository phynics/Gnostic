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
    if ! grep -F --quiet -- "$needle" "$file"; then
        fail "$name (missing: $needle)"
    fi
}

assert_bind_once() {
    host_path=$1
    destination=$2
    expected="$host_path:$destination"
    file=$3
    name=$4
    if [ ! -f "$file" ]; then
        fail "$name (runtime did not record arguments)"
        return
    fi
    count=$(awk -v expected="$expected" '
        $0 == expected { payload_count++; if (previous == "-v") paired_count++ }
        { previous = $0 }
        END { print payload_count + 0 ":" paired_count + 0 }
    ' "$file")
    [ "$count" = "1:1" ] || fail "$name (expected one -v $expected bind, got $count)"
}

assert_precedes() {
    earlier=$1
    later=$2
    file=$3
    name=$4
    if [ ! -f "$file" ]; then
        fail "$name (runtime did not record arguments)"
        return
    fi
    order=$(awk -v earlier="$earlier" -v later="$later" '
        $0 == earlier && !earlier_line { earlier_line = NR }
        $0 == later && !later_line { later_line = NR }
        END { print earlier_line + 0 ":" later_line + 0 }
    ' "$file")
    case $order in
        *:0|0:*) fail "$name (missing arguments: $order)" ;;
        *)
            earlier_line=${order%%:*}
            later_line=${order#*:}
            [ "$earlier_line" -lt "$later_line" ] || fail "$name (order: $order)"
            ;;
    esac
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
        GNOSTIC_DEVCONTAINER=0 \
        CONTAINER_RUNTIME= \
        BUILD_DIR="$fixture_dir/runtime-build" \
        "$root_dir/.devcontainer/run.sh" true
    assert_status 1 "$run_status" "missing runtime"
    assert_contains "No podman or docker runtime found" "$output" "missing runtime diagnostic"
}

test_invalid_build_lock_fails() {
    output="$fixture_dir/build-lock.out"
    run_capture "$output" env \
        GNOSTIC_DEVCONTAINER=1 \
        BUILD_LOCK_TIMEOUT=not-a-number \
        BUILD_DIR="$fixture_dir/invalid-lock-build" \
        "$root_dir/.devcontainer/run.sh" true
    assert_status 2 "$run_status" "invalid BUILD_LOCK"
    assert_contains "BUILD_LOCK_TIMEOUT must be a non-negative integer" "$output" "invalid build lock timeout diagnostic"
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
        GNOSTIC_DEVCONTAINER=0 \
        CONTAINER_RUNTIME="$runtime" \
        FAKE_RUNTIME_ARGUMENTS="$captured" \
        BUILD_DIR="$build_dir" \
        SPM_CACHE_DIR="$cache_dir" \
        EXTRA_CONTAINER_MOUNTS="-v $extra_dir:/extra:ro" \
        IMAGE=fixture-image \
        "$root_dir/.devcontainer/run.sh" swift --version
    assert_status 0 "$run_status" "fake runtime invocation"

    assert_bind_once "$root_dir" /workspace "$captured" "repository bind"
    assert_bind_once "$build_dir" /workspace/.build "$captured" "build bind"
    assert_bind_once "$cache_dir" /workspace/.swiftpm-cache "$captured" "SwiftPM cache bind"
    assert_bind_once "$extra_dir" /extra:ro "$captured" "extra bind"
    assert_precedes "$extra_dir:/extra:ro" fixture-image "$captured" "extra bind precedes image"
}

test_failing_child_releases_lock() {
    output="$fixture_dir/lock.out"
    build_dir="$fixture_dir/locked-build"
    run_capture "$output" env \
        GNOSTIC_DEVCONTAINER=1 \
        GNOSTIC_LOCK_BACKEND=mkdir \
        BUILD_DIR="$build_dir" \
        "$root_dir/.devcontainer/run.sh" sh -c 'exit 23'
    assert_status 23 "$run_status" "failing child exit status"
    [ ! -d "$build_dir.lock" ] || fail "failing child releases fallback build lock"
}

test_container_smoke_delegates_to_smoke_script() {
    runtime="$fixture_dir/smoke-fake-runtime"
    captured="$fixture_dir/smoke-runtime-arguments"
    cat >"$runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$FAKE_RUNTIME_ARGUMENTS"
EOF
    chmod +x "$runtime"

    output="$fixture_dir/container-smoke.out"
    run_capture "$output" env \
        GNOSTIC_DEVCONTAINER=0 \
        CONTAINER_RUNTIME="$runtime" \
        FAKE_RUNTIME_ARGUMENTS="$captured" \
        BUILD_DIR="$fixture_dir/smoke-build" \
        SPM_CACHE_DIR="$fixture_dir/smoke-cache" \
        IMAGE=fixture-image \
        make -C "$root_dir" container-smoke
    assert_status 0 "$run_status" "make container-smoke fake runtime invocation"
    assert_contains "/workspace/Scripts/container-smoke.sh" "$captured" "container smoke script delegation"
}

test_repository_container_smoke_script_is_executable() {
    [ -x "$root_dir/Scripts/container-smoke.sh" ] || fail "repository container smoke script is executable"
}

test_absent_container_smoke_script_fails_directly() {
    output="$fixture_dir/absent-container-smoke.out"
    run_capture "$output" "$root_dir/Scripts/absent-container-smoke.sh"
    if [ "$run_status" -eq 0 ]; then
        fail "absent container smoke script fails directly"
    fi
}

test_missing_manifest_guard_fails_for_tooling_only_fixture() {
    tooling_root="$fixture_dir/tooling-only"
    runtime="$fixture_dir/guard-fake-runtime"
    captured="$fixture_dir/guard-runtime-arguments"
    mkdir -p "$tooling_root"
    cp "$root_dir/Makefile" "$tooling_root/Makefile"
    cp -R "$root_dir/.devcontainer" "$tooling_root/.devcontainer"
    cat >"$runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$FAKE_RUNTIME_ARGUMENTS"
EOF
    chmod +x "$runtime"

    for target in resolve build test verify; do
        output="$fixture_dir/make-$target.out"
        run_capture "$output" env \
            GNOSTIC_DEVCONTAINER=0 \
            CONTAINER_RUNTIME="$runtime" \
            FAKE_RUNTIME_ARGUMENTS="$captured" \
            BUILD_DIR="$fixture_dir/guard-build-$target" \
            make -C "$tooling_root" "$target"
        assert_status 2 "$run_status" "make $target on tooling-only fixture"
        assert_contains "Package.swift is not present on this branch" "$output" "make $target missing manifest diagnostic"
    done

    [ ! -f "$captured" ] || fail "missing manifest guard does not build"
}

test_dev_stack_rejects_unknown_command() {
    output="$fixture_dir/dev-stack-usage.out"
    run_capture "$output" env \
        GNOSTIC_BUILD_ROOT="$fixture_dir/dev-stack-build" \
        "$root_dir/Scripts/dev-stack.sh" bogus
    assert_status 1 "$run_status" "dev-stack unknown command"
    assert_contains "usage: $root_dir/Scripts/dev-stack.sh up|status|down" "$output" "dev-stack usage diagnostic"

    output="$fixture_dir/dev-stack-env.out"
    run_capture "$output" env -u GNOSTIC_BUILD_ROOT "$root_dir/Scripts/dev-stack.sh" up
    assert_status 2 "$run_status" "dev-stack missing build root"
    assert_contains "GNOSTIC_BUILD_ROOT" "$output" "dev-stack build root diagnostic"
}

test_worktree_build_root_matches_wrapper() {
    main="$fixture_dir/worktree-main"
    worktree="$fixture_dir/worktree-checkout"
    mkdir -p "$main/Scripts" "$main/.devcontainer"
    cp "$root_dir/Makefile" "$main/Makefile"
    cp "$root_dir/Scripts/gnostic-container.sh" "$main/Scripts/gnostic-container.sh"
    cp "$root_dir/Scripts/gnostic-build-path.sh" "$main/Scripts/gnostic-build-path.sh"
    cp "$root_dir/.devcontainer/Dockerfile" "$main/.devcontainer/Dockerfile"
    git -C "$main" init -q
    git -C "$main" -c user.email=harness@example.invalid -c user.name=harness commit -q --allow-empty -m init
    git -C "$main" worktree add -q "$worktree"
    mkdir -p "$worktree/Scripts" "$worktree/.devcontainer"
    cp "$root_dir/Makefile" "$worktree/Makefile"
    cp "$root_dir/Scripts/gnostic-container.sh" "$worktree/Scripts/gnostic-container.sh"
    cp "$root_dir/Scripts/gnostic-build-path.sh" "$worktree/Scripts/gnostic-build-path.sh"
    cp "$root_dir/.devcontainer/Dockerfile" "$worktree/.devcontainer/Dockerfile"

    output="$fixture_dir/worktree-make.out"
    run_capture "$output" env -u BUILD_CACHE_ROOT -u BUILD_DIR IMAGE=fixture-image make -n -C "$worktree" build
    assert_status 0 "$run_status" "worktree build dry run"
    build_dir=$(env -u BUILD_CACHE_ROOT -u BUILD_DIR "$worktree/Scripts/gnostic-build-path.sh" build-dir)
    assert_contains "$build_dir" "$output" "Makefile resolves the worktree-specific build directory"

    mkdir -p "$build_dir/bin"
    printf '#!/bin/sh\nexit 0\n' >"$build_dir/bin/gnostic"
    chmod +x "$build_dir/bin/gnostic"
    printf '%s\n' /workspace/.build/bin/gnostic >"$build_dir/gnostic-bin-path"
    git -C "$worktree" rev-parse HEAD >"$build_dir/gnostic-build-revision"
    output="$fixture_dir/worktree-wrapper.out"
    run_capture "$output" env -u GNOSTIC_BUILD_ROOT -u BUILD_CACHE_ROOT -u BUILD_DIR "$worktree/Scripts/gnostic-container.sh" --wrapper-info
    assert_status 0 "$run_status" "worktree wrapper discovers build metadata"
    assert_contains "build-root $build_dir" "$output" "worktree wrapper shares the Makefile build root"
    assert_contains "binary /workspace/.build/bin/gnostic" "$output" "worktree wrapper uses validated executable metadata"
}

test_direct_command_preserves_exit_status
test_missing_runtime_fails
test_invalid_build_lock_fails
test_runtime_receives_each_mount_once
test_failing_child_releases_lock
test_container_smoke_delegates_to_smoke_script
test_repository_container_smoke_script_is_executable
test_absent_container_smoke_script_fails_directly
test_missing_manifest_guard_fails_for_tooling_only_fixture
test_dev_stack_rejects_unknown_command
test_worktree_build_root_matches_wrapper

if [ "$failures" -gt 0 ]; then
    echo "$failures harness test(s) failed" >&2
    exit 1
fi

echo "11 harness tests passed"
