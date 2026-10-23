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
    if (!target || /PositronicKit|PKContracts|GnosticPositronicBackend/.test(dependencies)) process.exit(1);
});
'

bin=$(swift build "${swift_flags[@]}" --product gnostic-runner --show-bin-path)/gnostic-runner
help=$("$bin" --help 2>&1)
status=$?
printf '%s\n' "$help"
test "$status" -eq 0
! printf '%s\n' "$help" | grep -F -- "--scenario"

pgrep mosquitto >/dev/null 2>&1 || mosquitto -c /etc/mosquitto/gnostic.conf -d
broker_ready=0
for attempt in {1..50}; do
    if mosquitto_pub -h 127.0.0.1 -t "gnostic/runner-smoke/readiness-$$" -m ready >/dev/null 2>&1; then
        broker_ready=1
        break
    fi
    sleep 0.1
done
if [ "$broker_ready" -ne 1 ]; then
    printf 'Mosquitto did not accept connections for runner smoke.\n' >&2
    exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT INT TERM
runner_log="$scratch/runner.log"

run_until_online() {
    local label=$1
    shift
    : > "$runner_log"
    stdbuf -oL "$@" >"$runner_log" 2>&1 &
    local runner_pid=$!
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
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    cat "$runner_log"
    if [ "$ready" -ne 0 ]; then
        echo "runner did not come online for: $label" >&2
        return 1
    fi
}

cat > "$scratch/letta.json" <<'JSON'
{
  "schemaVersion": 2,
  "broker": { "host": "127.0.0.1", "port": 1883, "namespace": "gnostic-smoke-letta" },
  "node": { "id": "e51d0000-0000-4000-8000-000000000001", "kind": "node", "approvalMode": "auto", "logLevel": "info" },
  "ascendants": [
    {
      "id": "e51d0000-0000-4000-8000-000000000002",
      "kind": "letta",
      "name": "Letta",
      "description": "",
      "metadata": {},
      "backend": {
        "kind": "letta",
        "schemaVersion": 1,
        "settings": { "serverURL": "http://127.0.0.1:8283", "model": "openai/test-model" },
        "secrets": {}
      },
      "defaultTimelineID": "e51d0000-0000-4000-8000-000000000003"
    }
  ],
  "timelines": [
    { "id": "e51d0000-0000-4000-8000-000000000003", "kind": "timeline", "title": "Letta", "operatingAscendantID": "e51d0000-0000-4000-8000-000000000002", "flags": [], "attachments": [] }
  ],
  "workspaces": []
}
JSON

run_until_online "Letta backend" \
    "$bin" --host 127.0.0.1 --port 1883 --namespace gnostic-smoke-letta --config "$scratch/letta.json"

echo "Gnostic runner smoke passed"
