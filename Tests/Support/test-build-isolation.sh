#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
fixture_dir=$(mktemp -d)
build_path="$root_dir/Scripts/gnostic-build-path.sh"
lock_script="$root_dir/.devcontainer/lock.sh"
image_script="$root_dir/.devcontainer/build-image.sh"
focused_script="$root_dir/Scripts/run-focused-tests.sh"

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
    if [ ! -f "$file" ]; then
        fail "$name (missing output file)"
    elif ! grep -F --quiet -- "$needle" "$file"; then
        fail "$name (missing: $needle)"
    fi
}

run_capture() {
    output_file=$1
    shift
    run_status=0
    "$@" >"$output_file" 2>&1 || run_status=$?
}

test_build_paths_use_stable_canonical_worktree_ids() {
    main="$fixture_dir/repository"
    mkdir -p "$main/Scripts" "$main/.devcontainer" "$fixture_dir/left" "$fixture_dir/right"
    cp "$build_path" "$main/Scripts/gnostic-build-path.sh"
    cp "$root_dir/.devcontainer/Dockerfile" "$main/.devcontainer/Dockerfile"
    git -C "$main" init -q
    git -C "$main" add Scripts/gnostic-build-path.sh .devcontainer/Dockerfile
    git -C "$main" -c user.email=harness@example.invalid -c user.name=harness commit -q -m init
    git -C "$main" worktree add -q -b left "$fixture_dir/left/project"
    git -C "$main" worktree add -q -b right "$fixture_dir/right/project"

    main_id=$("$main/Scripts/gnostic-build-path.sh" worktree-id)
    repeated_id=$("$main/Scripts/gnostic-build-path.sh" worktree-id)
    left_id=$("$fixture_dir/left/project/Scripts/gnostic-build-path.sh" worktree-id)
    right_id=$("$fixture_dir/right/project/Scripts/gnostic-build-path.sh" worktree-id)
    [ "$main_id" = "$repeated_id" ] || fail "canonical worktree ID is stable"
    [ "$main_id" != "$left_id" ] || fail "main checkout and worktree have distinct IDs"
    [ "$left_id" != "$right_id" ] || fail "same-basename checkouts have distinct IDs"

    debug_dir=$(env -u BUILD_CACHE_ROOT -u BUILD_DIR "$main/Scripts/gnostic-build-path.sh" build-dir)
    release_dir=$(env -u BUILD_CACHE_ROOT -u BUILD_DIR BUILD_CONFIGURATION=release "$main/Scripts/gnostic-build-path.sh" build-dir)
    arm_dir=$(env -u BUILD_CACHE_ROOT -u BUILD_DIR BUILD_TARGET_PLATFORM=linux-arm64 "$main/Scripts/gnostic-build-path.sh" build-dir)
    explicit_dir=$(env -u BUILD_CACHE_ROOT BUILD_DIR="$fixture_dir/explicit" "$main/Scripts/gnostic-build-path.sh" build-dir)
    case $debug_dir in */worktrees/*/debug) ;; *) fail "default path includes worktree and configuration namespaces: $debug_dir" ;; esac
    [ "$debug_dir" != "$release_dir" ] || fail "debug and release scratch paths are isolated"
    [ "$debug_dir" != "$arm_dir" ] || fail "target platform scratch paths are isolated"
    [ "$explicit_dir" = "$fixture_dir/explicit" ] || fail "explicit BUILD_DIR override is preserved"
}

test_concurrent_build_path_resolution_is_deterministic() {
    first="$fixture_dir/path-first"
    second="$fixture_dir/path-second"
    third="$fixture_dir/path-third"
    env -u BUILD_CACHE_ROOT -u BUILD_DIR "$build_path" build-dir >"$first" & p1=$!
    env -u BUILD_CACHE_ROOT -u BUILD_DIR "$build_path" build-dir >"$second" & p2=$!
    env -u BUILD_CACHE_ROOT -u BUILD_DIR "$build_path" build-dir >"$third" & p3=$!
    wait "$p1" || fail "first concurrent path resolution"
    wait "$p2" || fail "second concurrent path resolution"
    wait "$p3" || fail "third concurrent path resolution"
    cmp -s "$first" "$second" || fail "concurrent resolutions produce the same build directory"
    cmp -s "$first" "$third" || fail "all concurrent resolutions agree"
}

run_lock_pair() {
    backend=$1
    build_dir=$2
    event_file=$3
    mkdir -p "$build_dir"
    : > "$event_file"
    for worker in 1 2; do
        GNOSTIC_LOCK_BACKEND="$backend" BUILD_LOCK_POLL_INTERVAL=1 \
            "$lock_script" "$build_dir" 8 sh -c \
            'printf "start %s\n" "$1" >> "$2"; sleep 1; printf "end %s\n" "$1" >> "$2"' \
            sh "$worker" "$event_file" >"$event_file.$worker.log" 2>&1 &
        lock_pids="$lock_pids $!"
    done
    for lock_pid in $lock_pids; do wait "$lock_pid" || fail "$backend locks serialize commands sharing a build directory"; done
    lock_pids=
    awk '
        /^start / { if (active) exit 1; active = 1 }
        /^end / { if (!active) exit 1; active = 0 }
        END { if (active) exit 1 }
    ' "$event_file" || fail "$backend same-directory commands never overlap"
}

test_build_locks_serialize_shared_and_allow_distinct_directories() {
    lock_pids=
    run_lock_pair auto "$fixture_dir/auto-build" "$fixture_dir/auto-events"
    run_lock_pair mkdir "$fixture_dir/fallback-build" "$fixture_dir/fallback-events"

    for backend in auto mkdir; do
        marker_a="$fixture_dir/${backend}-a.ready"
        marker_b="$fixture_dir/${backend}-b.ready"
        rm -f "$marker_a" "$marker_b"
        GNOSTIC_LOCK_BACKEND="$backend" "$lock_script" "$fixture_dir/${backend}-build-a" 5 sh -c \
            'touch "$1"; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$2" ] && exit 0; sleep 0.1; done; exit 1' \
            sh "$marker_a" "$marker_b" >"$fixture_dir/${backend}-a.log" 2>&1 & pid_a=$!
        GNOSTIC_LOCK_BACKEND="$backend" "$lock_script" "$fixture_dir/${backend}-build-b" 5 sh -c \
            'touch "$1"; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$2" ] && exit 0; sleep 0.1; done; exit 1' \
            sh "$marker_b" "$marker_a" >"$fixture_dir/${backend}-b.log" 2>&1 & pid_b=$!
        wait "$pid_a" || fail "$backend distinct build directories run concurrently"
        wait "$pid_b" || fail "$backend distinct build directories run concurrently"
    done
}

test_lock_timeout_cancellation_and_stale_recovery() {
    build_dir="$fixture_dir/lock-timeout-build"
    marker="$fixture_dir/lock-active"
    mkdir -p "$build_dir"
    GNOSTIC_LOCK_BACKEND=mkdir "$lock_script" "$build_dir" 15 sh -c 'touch "$1"; exec sleep 30' sh "$marker" \
        >"$fixture_dir/lock-holder.log" 2>&1 & holder_pid=$!
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ -e "$marker" ] && break
        sleep 0.1
    done
    if [ ! -e "$marker" ]; then fail "fallback lock holder started"; kill -TERM "$holder_pid" 2>/dev/null || true; wait "$holder_pid" 2>/dev/null || true; return; fi

    owner_pid=
    IFS= read -r owner_pid < "$build_dir.lock/owner" || true
    run_capture "$fixture_dir/lock-timeout.log" env GNOSTIC_LOCK_BACKEND=mkdir "$lock_script" "$build_dir" 1 true
    assert_status 75 "$run_status" "build lock timeout has a distinct exit status"
    assert_contains "$build_dir" "$fixture_dir/lock-timeout.log" "lock timeout identifies the resource"
    assert_contains "owner pid $owner_pid" "$fixture_dir/lock-timeout.log" "lock timeout reports its active owner"
    kill -0 "$owner_pid" 2>/dev/null || fail "timed-out waiter preserves an active owner lock"
    [ -d "$build_dir.lock" ] || fail "timed-out waiter leaves the active lock intact"

    kill -TERM "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    [ ! -d "$build_dir.lock" ] || fail "cancellation releases a fallback lock"

    stale_dir="$fixture_dir/stale-build.lock"
    mkdir -p "$fixture_dir/stale-build" "$stale_dir"
    printf '%s\n' 99999999 > "$stale_dir/owner"
    run_capture "$fixture_dir/stale-lock.log" env GNOSTIC_LOCK_BACKEND=mkdir "$lock_script" "$fixture_dir/stale-build" 3 true
    assert_status 0 "$run_status" "stale fallback lock is recovered"
    assert_contains "Removed stale build lock" "$fixture_dir/stale-lock.log" "stale lock recovery is reported"

    if command -v flock >/dev/null 2>&1; then
        flock_dir="$fixture_dir/flock-timeout-build"
        mkdir -p "$flock_dir"
        GNOSTIC_LOCK_BACKEND=flock "$lock_script" "$flock_dir" 15 sh -c 'touch "$1"; exec sleep 30' sh "$fixture_dir/flock-active" \
            >"$fixture_dir/flock-holder.log" 2>&1 & flock_pid=$!
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            [ -e "$fixture_dir/flock-active" ] && break
            sleep 0.1
        done
        flock_owner_pid=
        IFS= read -r flock_owner_pid < "$flock_dir.lock.owner" || true
        run_capture "$fixture_dir/flock-timeout.log" env GNOSTIC_LOCK_BACKEND=flock "$lock_script" "$flock_dir" 1 true
        assert_status 75 "$run_status" "flock backend timeout has a distinct exit status"
        assert_contains "owner pid $flock_owner_pid" "$fixture_dir/flock-timeout.log" "flock timeout reports its active owner"
        kill -TERM "$flock_pid" 2>/dev/null || true
        wait "$flock_pid" 2>/dev/null || true
    fi
}

test_image_fingerprint_reuses_and_invalidates_builds() {
    context="$fixture_dir/image-context"
    mkdir -p "$context/.devcontainer/patches" "$context/Scripts"
    cp "$root_dir/.devcontainer/Dockerfile" "$context/.devcontainer/Dockerfile"
    cp "$root_dir/.dockerignore" "$context/.dockerignore"
    cp "$root_dir/.devcontainer/patches/chibi-cell-timeout.patch" "$context/.devcontainer/patches/chibi-cell-timeout.patch"
    cp "$root_dir/Scripts/build-chibi-rlm.sh" "$context/Scripts/build-chibi-rlm.sh"
    cp "$root_dir/Scripts/gnostic-rlm-limit-exec.c" "$context/Scripts/gnostic-rlm-limit-exec.c"
    cp "$root_dir/Scripts/install-rlm-limit-exec.sh" "$context/Scripts/install-rlm-limit-exec.sh"
    runtime="$fixture_dir/image-runtime"
    cat > "$runtime" <<'RUNTIME'
#!/bin/sh
case $1:$2 in
    image:inspect)
        [ -f "$FAKE_IMAGE_LABEL" ] || exit 1
        IFS= read -r label < "$FAKE_IMAGE_LABEL"
        printf '%s\n' "$label"
        ;;
    build:--label)
        shift
        while [ "$#" -gt 0 ]; do
            case $1 in
                --label) label=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s\n' "${label#*=}" > "$FAKE_IMAGE_LABEL"
        printf 'build\n' >> "$FAKE_IMAGE_BUILDS"
        ;;
    *) exit 2 ;;
esac
RUNTIME
    chmod +x "$runtime"

    env FAKE_IMAGE_LABEL="$fixture_dir/image-label" FAKE_IMAGE_BUILDS="$fixture_dir/image-builds" \
        "$image_script" "$runtime" fixture-image "$context" >"$fixture_dir/image-first.log" 2>&1
    env FAKE_IMAGE_LABEL="$fixture_dir/image-label" FAKE_IMAGE_BUILDS="$fixture_dir/image-builds" \
        "$image_script" "$runtime" fixture-image "$context" >"$fixture_dir/image-reuse.log" 2>&1
    assert_contains "Reusing unchanged development image" "$fixture_dir/image-reuse.log" "matching image fingerprint is reused"
    [ "$(wc -l < "$fixture_dir/image-builds" | tr -d ' ')" = 1 ] || fail "unchanged image is built once"

    printf '\n# system dependency update\n' >> "$context/.devcontainer/Dockerfile"
    env FAKE_IMAGE_LABEL="$fixture_dir/image-label" FAKE_IMAGE_BUILDS="$fixture_dir/image-builds" \
        "$image_script" "$runtime" fixture-image "$context" >"$fixture_dir/image-invalidated.log" 2>&1
    assert_contains "Building development image" "$fixture_dir/image-invalidated.log" "changed image input invalidates the image"
    [ "$(wc -l < "$fixture_dir/image-builds" | tr -d ' ')" = 2 ] || fail "changed image input triggers a rebuild"
}

test_focused_runner_bounds_selection_and_preserves_failures() {
    work="$fixture_dir/focused-work"
    bin="$fixture_dir/focused-bin"
    mkdir -p "$work" "$bin"
    cat > "$bin/timeout" <<'TIMEOUT'
#!/bin/sh
shift 3
if [ "${FAKE_TIMEOUT_MODE:-}" = timeout ] && [ "${1:-}" = swift ] && [ "${2:-}" = test ]; then
    echo 'fixture timed out' >&2
    exit 124
fi
exec "$@"
TIMEOUT
    cat > "$bin/swift" <<'SWIFT'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SWIFT_ARGS"
case $1 in
    build)
        case " $* " in
            *' --show-bin-path '*) printf '%s\n' "$FAKE_SWIFT_BIN_DIR" ;;
            *) echo 'swift build fixture passed' ;;
        esac
        exit 0
        ;;
    test)
        case ${FAKE_SWIFT_MODE:-success} in
            unmatched) echo 'Test run with 0 tests'; exit 0 ;;
            failure) echo 'fixture failure'; exit 42 ;;
            *) echo 'Test run with 1 test'; exit 0 ;;
        esac
        ;;
esac
exit 2
SWIFT
    cat > "$bin/npm" <<'NPM'
#!/bin/sh
exit 0
NPM
    cat > "$bin/pgrep" <<'PGREP'
#!/bin/sh
exit 0
PGREP
    mkdir -p "$work/bin"
    printf '#!/bin/sh\nexit 0\n' >"$work/bin/gnostic"
    chmod +x "$bin/timeout" "$bin/swift" "$bin/npm" "$bin/pgrep" "$work/bin/gnostic"
    run_capture "$fixture_dir/focused-success.log" env PATH="$bin:$PATH" FAKE_SWIFT_ARGS="$fixture_dir/swift-args" \
        FAKE_SWIFT_BIN_DIR="$work/bin" \
        FILTER=GnosticSomeTests N=2 TEST_TIMEOUT=30 SWIFT_FLAGS='--cache-path /workspace/.swiftpm-cache -Xswiftc -warnings-as-errors' \
        bash -c 'cd "$1" && bash "$2"' sh "$work" "$focused_script"
    assert_status 0 "$run_status" "focused and repeat test run succeeds"
    assert_contains "Test run with 1 test" "$work/.testing/focused-GnosticSomeTests-1.log" "focused test captures diagnostics"
    assert_contains "-warnings-as-errors" "$fixture_dir/swift-args" "focused tests preserve strict compiler flags"
    [ "$(awk '$1 == "test" { count++ } END { print count + 0 }' "$fixture_dir/swift-args")" = 2 ] || fail "repeat command executes exactly N runs"
    assert_contains "--skip-build" "$fixture_dir/swift-args" "repeat command reuses the first build"

    run_capture "$fixture_dir/focused-unmatched.log" env PATH="$bin:$PATH" FAKE_SWIFT_ARGS="$fixture_dir/swift-unmatched-args" \
        FAKE_SWIFT_BIN_DIR="$work/bin" FAKE_SWIFT_MODE=unmatched FILTER=NoSuchTests N=1 bash -c 'cd "$1" && bash "$2"' sh "$work" "$focused_script"
    assert_status 1 "$run_status" "unmatched focused filter fails"
    assert_contains "No tests matched FILTER=NoSuchTests" "$fixture_dir/focused-unmatched.log" "unmatched filter is explicit"

    run_capture "$fixture_dir/focused-failure.log" env PATH="$bin:$PATH" FAKE_SWIFT_ARGS="$fixture_dir/swift-failure-args" \
        FAKE_SWIFT_BIN_DIR="$work/bin" FAKE_SWIFT_MODE=failure FILTER=GnosticSomeTests N=1 bash -c 'cd "$1" && bash "$2"' sh "$work" "$focused_script"
    assert_status 42 "$run_status" "focused test preserves the Swift test exit status"
    assert_contains "fixture failure" "$work/.testing/focused-GnosticSomeTests-1.log" "failure diagnostics are retained"

    run_capture "$fixture_dir/focused-timeout.log" env PATH="$bin:$PATH" FAKE_SWIFT_ARGS="$fixture_dir/swift-timeout-args" \
        FAKE_SWIFT_BIN_DIR="$work/bin" FAKE_TIMEOUT_MODE=timeout FILTER=GnosticSomeTests N=1 bash -c 'cd "$1" && bash "$2"' sh "$work" "$focused_script"
    assert_status 124 "$run_status" "focused test preserves timeout status"
    assert_contains "fixture timed out" "$work/.testing/focused-GnosticSomeTests-1.log" "focused timeout diagnostics are retained"
}

test_container_timeout_stops_and_removes_the_container() {
    runtime="$fixture_dir/hanging-runtime"
    cat > "$runtime" <<'RUNTIME'
#!/bin/sh
case $1 in
    run)
        case " $* " in *gnostic-owner-*) exit 0 ;; esac
        printf '%s\n' "$$" > "$FAKE_RUN_PID"
        trap 'exit 0' TERM INT
        while :; do sleep 1; done
        ;;
    stop)
        touch "$FAKE_STOPPED"
        if [ -f "$FAKE_RUN_PID" ]; then IFS= read -r pid < "$FAKE_RUN_PID"; kill -TERM "$pid" 2>/dev/null || true; fi
        ;;
    rm) touch "$FAKE_REMOVED" ;;
    *) exit 2 ;;
esac
RUNTIME
    chmod +x "$runtime"
    run_capture "$fixture_dir/container-timeout.log" env GNOSTIC_DEVCONTAINER=0 CONTAINER_RUNTIME="$runtime" \
        FAKE_RUN_PID="$fixture_dir/runtime-pid" FAKE_STOPPED="$fixture_dir/runtime-stopped" FAKE_REMOVED="$fixture_dir/runtime-removed" \
        BUILD_DIR="$fixture_dir/container-build" SPM_CACHE_DIR="$fixture_dir/container-cache" CONTAINER_TIMEOUT=1 \
        "$root_dir/.devcontainer/run.sh" true
    assert_status 124 "$run_status" "container runner timeout is reported"
    assert_contains "Container command timed out" "$fixture_dir/container-timeout.log" "timeout diagnostic identifies container execution"
    [ -f "$fixture_dir/runtime-stopped" ] || fail "timed-out container is stopped"
    [ -f "$fixture_dir/runtime-removed" ] || fail "timed-out container is removed"
}

test_clean_preserves_shared_cache_and_test_logs() {
    clean_root="$fixture_dir/clean-fixture"
    clean_build="$fixture_dir/clean-build"
    mkdir -p "$clean_root/.devcontainer" "$clean_root/.swiftpm-cache" "$clean_root/.testing" "$clean_build"
    cp "$root_dir/Makefile" "$clean_root/Makefile"
    cp "$lock_script" "$clean_root/.devcontainer/lock.sh"
    printf '%s\n' dependency-cache > "$clean_root/.swiftpm-cache/marker"
    printf '%s\n' test-log > "$clean_root/.testing/marker"
    printf '%s\n' build-artifact > "$clean_build/marker"

    run_capture "$fixture_dir/clean-target.log" env -u BUILD_DIR -u BUILD_CACHE_ROOT \
        make -C "$clean_root" clean BUILD_DIR="$clean_build" GNOSTIC_LOCK_BACKEND=mkdir
    assert_status 0 "$run_status" "clean target succeeds"
    [ -f "$clean_root/.swiftpm-cache/marker" ] || fail "clean preserves the shared SwiftPM cache"
    [ -f "$clean_root/.testing/marker" ] || fail "clean preserves test logs"
    [ ! -e "$clean_build/marker" ] || fail "clean removes the locked worktree build directory"
}

test_build_paths_use_stable_canonical_worktree_ids
test_concurrent_build_path_resolution_is_deterministic
test_build_locks_serialize_shared_and_allow_distinct_directories
test_lock_timeout_cancellation_and_stale_recovery
test_image_fingerprint_reuses_and_invalidates_builds
test_focused_runner_bounds_selection_and_preserves_failures
test_container_timeout_stops_and_removes_the_container
test_clean_preserves_shared_cache_and_test_logs

if [ "$failures" -gt 0 ]; then
    echo "$failures build-isolation test(s) failed" >&2
    exit 1
fi

echo "8 build isolation tests passed"
