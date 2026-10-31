#!/usr/bin/env bash

# Smoke-tests the runner's clean, process-independent composition.
#
# Invoked by `make runner-smoke`, which supplies the container and build
# environment. The runner must not link PositronicKit; the reference Runtime
# owns that dependency behind the ACP stdio boundary.

set -euo pipefail

cd /workspace

swift_flags=(--cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --build-system native --quiet -Xswiftc -warnings-as-errors)
case ${BUILD_CONFIGURATION:-debug} in
    debug) ;;
    release) swift_flags+=(-c release) ;;
    *) echo "BUILD_CONFIGURATION must be debug or release, got: ${BUILD_CONFIGURATION}" >&2; exit 2 ;;
esac

test ! -e Sources/GnosticRunner/FixtureScenario.swift

package=$(swift package dump-package "${swift_flags[@]}")
printf '%s\n' "$package" | node -e '
let data = "";
process.stdin.on("data", (chunk) => { data += chunk; });
process.stdin.on("end", () => {
    const targets = JSON.parse(data).targets;
    const target = targets.find(({ name }) => name === "GnosticRunner");
    const dependencies = JSON.stringify(target?.dependencies ?? []);
    if (!target || /PositronicKit|PKContracts|GnosticPositronic|GnosticLegacy|GnosticLetta/.test(dependencies)) process.exit(1);
});
'

# --show-bin-path prints a path without building. Build both products here so
# that the smoke never runs an older binary from a restored build cache.
swift build "${swift_flags[@]}" --product gnostic-runner
swift build "${swift_flags[@]}" --product gnostic
bin=$(swift build "${swift_flags[@]}" --product gnostic-runner --show-bin-path)/gnostic-runner
cli_bin=$(swift build "${swift_flags[@]}" --product gnostic --show-bin-path)/gnostic
help=$("$bin" --help 2>&1)
status=$?
printf '%s\n' "$help"
test "$status" -eq 0
! printf '%s\n' "$help" | grep -F -- "--scenario"

scratch=$(mktemp -d)
mosquitto_log="$scratch/mosquitto.log"
mosquitto_config="$scratch/mosquitto.conf"
mosquitto_pid=
runner_pid=
fixture_pid=
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [ "$status" -ne 0 ]; then
        local diagnostics="/workspace/.testing/runner-smoke-failure-$(date +%s)-$$"
        mkdir -p "$diagnostics" || true
        for name in runner.log mosquitto.log client.stderr fixture-initialize fixture-new-session fixture-prompt fixture-permission fixture-pid; do
            if [ -f "$scratch/$name" ]; then cp "$scratch/$name" "$diagnostics/$name" || true; fi
        done
        printf 'Runner smoke diagnostics saved to %s\n' "$diagnostics" >&2
    fi
    if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
        kill -TERM "$runner_pid" 2>/dev/null || true
        for _ in $(seq 1 50); do
            if ! kill -0 "$runner_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        kill -KILL "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
    fi
    if [ -z "$fixture_pid" ] && [ -s "$scratch/fixture-pid" ]; then
        fixture_pid=$(head -n1 "$scratch/fixture-pid")
    fi
    if [ -n "$fixture_pid" ] && kill -0 "$fixture_pid" 2>/dev/null; then
        kill -KILL "$fixture_pid" 2>/dev/null || true
    fi
    if [ -n "$mosquitto_pid" ]; then
        kill "$mosquitto_pid" 2>/dev/null || true
        wait "$mosquitto_pid" 2>/dev/null || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

readiness_topic="gnostic/runner-smoke/readiness-$$"
if ! mosquitto_pub -h 127.0.0.1 -t "$readiness_topic" -m ready >/dev/null 2>&1; then
    printf '%s\n' \
        'per_listener_settings true' \
        'listener 1883 127.0.0.1' \
        'allow_anonymous true' \
        'persistence false' \
        'log_dest stderr' >"$mosquitto_config"
    chmod 755 "$scratch"
    chmod 644 "$mosquitto_config"
    mosquitto -c "$mosquitto_config" >"$mosquitto_log" 2>&1 &
    mosquitto_pid=$!
fi
broker_ready=0
for attempt in {1..50}; do
    if mosquitto_pub -h 127.0.0.1 -t "$readiness_topic" -m ready >/dev/null 2>&1; then
        broker_ready=1
        break
    fi
    if [ -n "$mosquitto_pid" ] && ! kill -0 "$mosquitto_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if [ "$broker_ready" -ne 1 ]; then
    id >&2
    command -v mosquitto >&2
    ls -ld /tmp "$scratch" "$mosquitto_config" >&2 || true
    if [ -r "$mosquitto_config" ]; then
        printf 'Broker config is readable by the smoke process.\n' >&2
    fi
    if [ -f "$mosquitto_log" ]; then
        while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$mosquitto_log"
    fi
    printf 'Mosquitto did not accept connections for runner smoke.\n' >&2
    exit 1
fi

runner_log="$scratch/runner.log"

run_until_online() {
    local label=$1
    shift
    : > "$runner_log"
    stdbuf -oL "$@" >"$runner_log" 2>&1 &
    runner_pid=$!
    local ready=1
    for _ in $(seq 1 30); do
        if grep -F "gnostic-runner online at" "$runner_log" >/dev/null 2>&1; then
            ready=0
            break
        fi
        if ! kill -0 "$runner_pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    cat "$runner_log"
    if [ "$ready" -ne 0 ]; then
        kill "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
        echo "runner did not come online for: $label" >&2
        return 1
    fi
}

cat > "$scratch/acp.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "127.0.0.1", "port": 1883, "namespace": "gnostic-smoke-acp" },
  "node": { "id": "e51d0000-0000-4000-8000-000000000001", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "e51d0000-0000-4000-8000-000000000002",
      "kind": "acp-client",
      "name": "ACP fixture",
      "description": "",
      "metadata": {},
      "backend": {
        "kind": "acp-client",
        "schemaVersion": 1,
        "settings": {
          "command": "node",
          "args": "[\"/workspace/Tests/Fixtures/ACPAgent/agent.mjs\"]",
          "env": "{}"
        },
        "secrets": {}
      },
      "defaultTimelineID": "e51d0000-0000-4000-8000-000000000003"
    }
  ],
  "timelines": [
    { "id": "e51d0000-0000-4000-8000-000000000003", "kind": "timeline", "title": "ACP fixture", "operatingAscendantID": "e51d0000-0000-4000-8000-000000000002", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

node - "$scratch/acp.json" "$scratch" <<'NODE'
const fs = require("node:fs");
const [manifestPath, scratch] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
manifest.ascendants[0].backend.settings.env = JSON.stringify({
  GNOSTIC_ACP_FIXTURE_STATE: `${scratch}/fixture-sessions.json`,
  GNOSTIC_ACP_FIXTURE_INITIALIZE_FILE: `${scratch}/fixture-initialize`,
  GNOSTIC_ACP_FIXTURE_NEW_SESSION_FILE: `${scratch}/fixture-new-session`,
  GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE: `${scratch}/fixture-prompt`,
  GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE: `${scratch}/fixture-pid`,
  GNOSTIC_ACP_FIXTURE_PERMISSION: "1",
  GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME: "cancelled",
  GNOSTIC_ACP_FIXTURE_PERMISSION_RESULT_FILE: `${scratch}/fixture-permission`,
});
fs.writeFileSync(manifestPath, JSON.stringify(manifest));
NODE

mkdir -p "$scratch/client-state"

run_until_online "ACP backend" \
    env GNOSTIC_STATE_HOME="$scratch/state" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke-acp --config "$scratch/acp.json"

GNOSTIC_ACP_CLIENT_BINARY="$cli_bin" \
GNOSTIC_ACP_CLIENT_CONFIG="$scratch/acp.json" \
GNOSTIC_ACP_CLIENT_NAMESPACE=gnostic-smoke-acp \
GNOSTIC_ACP_CLIENT_STATE="$scratch/client-state" \
GNOSTIC_ACP_CLIENT_STDERR_FILE="$scratch/client.stderr" \
timeout --signal=TERM --kill-after=5s 90s node Tests/Fixtures/ACPAgent/runner-smoke.mjs

test -s "$scratch/fixture-initialize"
test -s "$scratch/fixture-new-session"
test -s "$scratch/fixture-prompt"

kill -TERM "$runner_pid"
wait "$runner_pid" || runner_status=$?
runner_status=${runner_status:-0}
test "$runner_status" -eq 0
runner_pid=
fixture_pid=$(head -n1 "$scratch/fixture-pid")
for _ in $(seq 1 50); do
    if ! kill -0 "$fixture_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
! kill -0 "$fixture_pid" 2>/dev/null

echo "Gnostic runner smoke passed"
