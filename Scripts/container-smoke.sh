#!/usr/bin/env bash

set -euo pipefail

swift --version | grep -F "Swift version 6.4"
cargo --version
git --version
node --version
npm --version
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 18)) process.exit(1)'
test "$(id -u)" = "${GNOSTIC_HOST_UID:-$(id -u)}"
test "$(id -g)" = "${GNOSTIC_HOST_GID:-$(id -g)}"
test -w /workspace
test -w /workspace/.build
guile --version | grep -F "GNU Guile) 3.0."
chibi-scheme -V | grep -F "chibi-scheme 0.12"
test "$(chibi-scheme -p '(+ 2 3)')" = "5"
bash /workspace/Scripts/test-rlm-limit-exec.sh /usr/local/bin/gnostic-rlm-limit-exec
test -w /workspace/.swiftpm-cache
smoke_dir=$(mktemp -d)
smoke_output="$smoke_dir/output"
mosquitto_log="$smoke_dir/mosquitto.log"
mosquitto_config="$smoke_dir/mosquitto.conf"
printf '%s\n' \
    'per_listener_settings true' \
    'listener 1883 127.0.0.1' \
    'allow_anonymous true' \
    'persistence false' \
    "pid_file $smoke_dir/mosquitto.pid" \
    'log_dest stderr' >"$mosquitto_config"
mosquitto -c "$mosquitto_config" >"$mosquitto_log" 2>&1 &
mosquitto_pid=$!
cleanup() {
    kill "$mosquitto_pid" 2>/dev/null || true
    wait "$mosquitto_pid" 2>/dev/null || true
    rm -rf "$smoke_dir"
}
trap cleanup EXIT INT TERM
broker_ready=0
for attempt in {1..50}; do
    if mosquitto_pub -h 127.0.0.1 -t gnostic/smoke/readiness -m ready >/dev/null 2>&1; then
        broker_ready=1
        break
    fi
    if ! kill -0 "$mosquitto_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if [ "$broker_ready" -ne 1 ]; then
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$mosquitto_log"
    printf 'Mosquitto did not accept connections after launch.\n' >&2
    exit 1
fi
mosquitto_pub -h 127.0.0.1 -t gnostic/smoke -m ready -r
mosquitto_sub -h 127.0.0.1 -t gnostic/smoke -C 1 -W 5 >"$smoke_output"
mosquitto_pub -h 127.0.0.1 -t gnostic/smoke -n -r
grep -Fx ready "$smoke_output"

echo "Gnostic container smoke passed"
