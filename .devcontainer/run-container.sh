#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
runtime=${CONTAINER_RUNTIME:-}
image=${IMAGE:-gnostic-dev:$("$root_dir/.devcontainer/image-fingerprint.sh" "$root_dir")}
workdir=${WORKDIR:-/workspace}
build_dir=${BUILD_DIR:-$("$root_dir/Scripts/gnostic-build-path.sh" build-dir)}
cache_namespace=${CACHE_NAMESPACE:-swift-$("$root_dir/Scripts/gnostic-build-path.sh" swift-version)-linux}
spm_cache_dir=${SPM_CACHE_DIR:-"${HOME}/.cache/gnostic/swiftpm/$cache_namespace"}
container_timeout=${CONTAINER_TIMEOUT:-3600}
extra_container_mounts=${EXTRA_CONTAINER_MOUNTS:-}
extra_container_env=${EXTRA_CONTAINER_ENV:-}

case $container_timeout in
    ''|*[!0-9]*|0) echo "CONTAINER_TIMEOUT must be a positive integer, got: $container_timeout" >&2; exit 2 ;;
esac
if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

# Rootless podman maps the host user to container root, so `--user $host_uid`
# runs as an unmapped subuid that cannot write the host-owned worktree, build,
# and cache bind mounts. `--userns=keep-id` maps the host user to the same uid
# and gid inside the container, keeping bind mounts writable. A rootful runtime
# needs no remap because `--user` already matches the host identity.
runtime_userns=
repair_supported=1
case $(basename -- "$runtime") in
    podman)
        runtime_userns=--userns=keep-id
        # Only a rootful runtime can chown root-owned artifacts. Rootless
        # podman cannot, and its user namespace would rewrite the ownership to
        # an unmapped subuid, so leave repair to rootful runtimes.
        repair_supported=0
        ;;
esac

mkdir -p "$build_dir" "$spm_cache_dir"
build_dir=$(CDPATH= cd -- "$build_dir" && pwd -P)
spm_cache_dir=$(CDPATH= cd -- "$spm_cache_dir" && pwd -P)

host_uid=$(id -u)
host_gid=$(id -g)
container_name="gnostic-run-${host_uid}-$$-$(date +%s)"
ownership_name="gnostic-owner-${host_uid}-$$-$(date +%s)"
status_dir=$(mktemp -d "${TMPDIR:-/tmp}/gnostic-container.XXXXXX")
status_file="$status_dir/exit-status"
container_started=0
ownership_started=0
runtime_pid=

cleanup_container() {
    if [ "$container_started" = 1 ]; then
        "$runtime" stop -t 5 "$container_name" >/dev/null 2>&1 || true
        "$runtime" rm -f "$container_name" >/dev/null 2>&1 || true
        container_started=0
    fi
    if [ "$ownership_started" = 1 ]; then
        "$runtime" stop -t 5 "$ownership_name" >/dev/null 2>&1 || true
        "$runtime" rm -f "$ownership_name" >/dev/null 2>&1 || true
        ownership_started=0
    fi
    rm -rf "$status_dir"
}

finish() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$runtime_pid" ]; then
        kill -TERM "$runtime_pid" 2>/dev/null || true
        wait "$runtime_pid" 2>/dev/null || true
        runtime_pid=
    fi
    cleanup_container
    exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Previous container runs used root and may have left ignored package trees,
# test logs, and shared caches that the caller UID cannot update. Repair only
# those generated paths.
repair_legacy_ownership=0
for relative_path in \
    Tests/Fixtures/ACPAgent/node_modules \
    Tests/Fixtures/OfficialACPClient/node_modules \
    Tests/Fixtures/PiACPClient/node_modules \
    .testing; do
    absolute_path="$root_dir/$relative_path"
    [ -e "$absolute_path" ] || continue
    if [ ! -w "$absolute_path" ]; then
        repair_legacy_ownership=1
        break
    fi
    if [ -d "$absolute_path" ]; then
        for child_path in "$absolute_path"/* "$absolute_path"/.[!.]*; do
            [ -e "$child_path" ] || continue
            if [ ! -w "$child_path" ]; then
                repair_legacy_ownership=1
                break 2
            fi
        done
    fi
done

# Caches restored from a previous root-owned run live outside the worktree.
repair_external_mounts=
repair_external_targets=
repair_index=0
for external_path in "$spm_cache_dir" "$build_dir"; do
    [ -e "$external_path" ] || continue
    [ -w "$external_path" ] && continue
    repair_index=$((repair_index + 1))
    repair_external_mounts="$repair_external_mounts -v $external_path:/gnostic-repair-$repair_index"
    repair_external_targets="$repair_external_targets /gnostic-repair-$repair_index"
done

needs_repair=0
[ "$repair_legacy_ownership" = 1 ] && needs_repair=1
[ -n "$repair_external_targets" ] && needs_repair=1

if [ "$needs_repair" = 1 ] && [ "$repair_supported" = 0 ]; then
    echo "Warning: root-owned generated artifacts are not writable and $runtime cannot repair them; remove and recreate the affected paths" >&2
fi

if [ "$repair_supported" = 1 ] && [ "$needs_repair" = 1 ]; then
    echo "Repairing ownership of legacy generated artifacts in $root_dir"
    ownership_started=1
    ownership_status=0
    timeout --signal=TERM --kill-after=5s "${container_timeout}s" \
        "$runtime" run --rm --name "$ownership_name" --user 0:0 -v "$root_dir:$workdir" $repair_external_mounts "$image" \
        sh -c 'owner=$1; shift; for path do [ ! -e "$path" ] || chown -R "$owner" "$path"; done' \
        sh "$host_uid:$host_gid" \
        /workspace/Tests/Fixtures/ACPAgent/node_modules \
        /workspace/Tests/Fixtures/OfficialACPClient/node_modules \
        /workspace/Tests/Fixtures/PiACPClient/node_modules \
        /workspace/.testing \
        $repair_external_targets || ownership_status=$?
    if [ "$ownership_status" -ne 0 ]; then
        echo "Legacy dependency ownership repair failed with exit status $ownership_status" >&2
        "$runtime" stop -t 5 "$ownership_name" >/dev/null 2>&1 || true
        "$runtime" rm -f "$ownership_name" >/dev/null 2>&1 || true
        ownership_started=0
        exit "$ownership_status"
    fi
    ownership_started=0
fi

run_container() {
    "$runtime" run --rm --name "$container_name" $runtime_userns --user "$host_uid:$host_gid" \
        -e HOME=/tmp -e "GNOSTIC_HOST_UID=$host_uid" -e "GNOSTIC_HOST_GID=$host_gid" \
        -e GNOSTIC_BUILD_REVISION -e BUILD_CONFIGURATION -e SWIFT_FLAGS -e FILTER -e N -e TEST_TIMEOUT \
        -v "$root_dir:$workdir" \
        -v "$build_dir:$workdir/.build" \
        -v "$spm_cache_dir:$workdir/.swiftpm-cache" \
        -w "$workdir" \
        $extra_container_env \
        $extra_container_mounts \
        "$image" "$@"
}

run_bounded() {
    (
        status=0
        run_container "$@" || status=$?
        printf '%s\n' "$status" > "$status_file"
    ) &
    runtime_pid=$!
    container_started=1
    start_seconds=$(date +%s)

    while [ ! -f "$status_file" ]; do
        now_seconds=$(date +%s)
        if [ "$((now_seconds - start_seconds))" -ge "$container_timeout" ]; then
            echo "Container command timed out after ${container_timeout}s; stopping $container_name" >&2
            "$runtime" stop -t 5 "$container_name" >/dev/null 2>&1 || true
            kill -TERM "$runtime_pid" 2>/dev/null || true
            wait "$runtime_pid" 2>/dev/null || true
            runtime_pid=
            "$runtime" rm -f "$container_name" >/dev/null 2>&1 || true
            container_started=0
            return 124
        fi
        sleep 1
    done

    wait "$runtime_pid" 2>/dev/null || true
    runtime_pid=
    child_status=
    IFS= read -r child_status < "$status_file" || true
    case $child_status in
        ''|*[!0-9]*) echo "Container runtime did not report an exit status; inspect $status_file" >&2; return 125 ;;
    esac
    container_started=0
    rm -rf "$status_dir"
    return "$child_status"
}

run_bounded "$@"
