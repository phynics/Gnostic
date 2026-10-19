#!/bin/sh

set -u

if [ "$#" -lt 3 ]; then
    echo "usage: $0 BUILD_DIR TIMEOUT_SECONDS COMMAND [ARG...]" >&2
    exit 2
fi

build_dir=$1
timeout_seconds=$2
shift 2
lock_path="${build_dir}.lock"
flock_owner_path="${lock_path}.owner"
recovery_path="${lock_path}.recovery"
backend=${GNOSTIC_LOCK_BACKEND:-auto}
poll_seconds=${BUILD_LOCK_POLL_INTERVAL:-1}

case $timeout_seconds in
    ''|*[!0-9]*) echo "BUILD_LOCK_TIMEOUT must be a non-negative integer, got: $timeout_seconds" >&2; exit 2 ;;
esac
case $backend in
    auto|flock|mkdir) ;;
    *) echo "GNOSTIC_LOCK_BACKEND must be auto, flock, or mkdir, got: $backend" >&2; exit 2 ;;
esac

if [ "$backend" = auto ]; then
    if command -v flock >/dev/null 2>&1; then backend=flock; else backend=mkdir; fi
fi
if [ "$backend" = flock ] && ! command -v flock >/dev/null 2>&1; then
    echo "flock lock backend requested but flock is unavailable" >&2
    exit 2
fi

start_seconds=$(date +%s)
command_pid=
fallback_owned=0
recovery_owned=0
flock_fd_open=0
flock_owned=0

release_fallback_lock() {
    if [ "$fallback_owned" = 1 ] && [ -r "$lock_path/owner" ]; then
        owner_pid=
        IFS= read -r owner_pid < "$lock_path/owner" || true
        if [ "$owner_pid" = "$$" ]; then
            rm -f "$lock_path/owner"
            rmdir "$lock_path" 2>/dev/null || true
        fi
        fallback_owned=0
    fi
}

release_recovery_lock() {
    if [ "$recovery_owned" = 1 ]; then
        rmdir "$recovery_path" 2>/dev/null || true
        recovery_owned=0
    fi
}

release_flock_lock() {
    if [ "$flock_fd_open" = 1 ]; then
        exec 9>&-
        flock_fd_open=0
    fi
    if [ "$flock_owned" = 1 ] && [ -r "$flock_owner_path" ]; then
        owner_pid=
        IFS= read -r owner_pid < "$flock_owner_path" || true
        if [ "$owner_pid" = "$$" ]; then rm -f "$flock_owner_path"; fi
        flock_owned=0
    fi
}

finish() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$command_pid" ]; then
        kill -TERM "$command_pid" 2>/dev/null || true
        wait "$command_pid" 2>/dev/null || true
        command_pid=
    fi
    release_fallback_lock
    release_recovery_lock
    release_flock_lock
    exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

waited_seconds() {
    now=$(date +%s)
    printf '%s' "$((now - start_seconds))"
}

if [ "$backend" = flock ]; then
    : > "$lock_path"
    exec 9>"$lock_path"
    flock_fd_open=1
    if ! flock -w "$timeout_seconds" -E 75 9; then
        owner_note=
        if [ -r "$flock_owner_path" ]; then
            IFS= read -r owner_pid < "$flock_owner_path" || true
            if [ -n "$owner_pid" ]; then
                if kill -0 "$owner_pid" 2>/dev/null; then owner_note="; owner pid $owner_pid"; else owner_note="; stale owner pid $owner_pid"; fi
            fi
        fi
        echo "Timed out after ${timeout_seconds}s waiting for build resource: $build_dir (lock: $lock_path)$owner_note" >&2
        exit 75
    fi
    flock_owned=1
    printf '%s\n' "$$" > "$flock_owner_path"
else
    deadline=$((start_seconds + timeout_seconds))
    while :; do
        if [ -d "$recovery_path" ]; then
            :
        elif mkdir "$lock_path" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_path/owner"
            fallback_owned=1
            if [ -d "$recovery_path" ]; then
                release_fallback_lock
            else
                break
            fi
        else
            stale_pid=
            if [ -r "$lock_path/owner" ]; then
                IFS= read -r stale_pid < "$lock_path/owner" || true
            fi
            if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null && mkdir "$recovery_path" 2>/dev/null; then
                recovery_owned=1
                current_pid=
                if [ -r "$lock_path/owner" ]; then
                    IFS= read -r current_pid < "$lock_path/owner" || true
                fi
                if [ "$current_pid" = "$stale_pid" ] && ! kill -0 "$current_pid" 2>/dev/null; then
                    stale_path="${lock_path}.stale.$$"
                    if mv "$lock_path" "$stale_path" 2>/dev/null; then
                        rm -f "$stale_path/owner"
                        rmdir "$stale_path" 2>/dev/null || true
                        echo "Removed stale build lock for resource: $build_dir (owner pid $stale_pid)" >&2
                    fi
                fi
                release_recovery_lock
            fi
        fi

        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            stale_note=
            if [ -r "$lock_path/owner" ]; then
                IFS= read -r stale_pid < "$lock_path/owner" || true
                if [ -n "$stale_pid" ]; then
                    if kill -0 "$stale_pid" 2>/dev/null; then stale_note="; owner pid $stale_pid"; else stale_note="; stale owner pid $stale_pid could not be safely reclaimed"; fi
                fi
            fi
            echo "Timed out after ${timeout_seconds}s waiting for build resource: $build_dir (lock: $lock_path)$stale_note" >&2
            exit 75
        fi
        sleep "$poll_seconds"
    done
fi

printf 'build lock acquired: resource=%s wait_seconds=%s backend=%s\n' "$build_dir" "$(waited_seconds)" "$backend" >&2

"$@" 9>&- &
command_pid=$!
wait "$command_pid"
status=$?
command_pid=
exit "$status"
